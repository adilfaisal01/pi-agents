# Agent modes for pi

Named modes with their own permissions: each one carries its own tool set, its own shell
policy, its own write scope, its own system-prompt contract, and optionally its own model.

pi core has no named-agent concept, so a mode here is tool-schema + prompt + model state,
switched in one place. It is a plugin because permissions are the one thing advice cannot
carry: a mode removes a tool from the schema, refuses a path at `tool_call`, and gates
bash through an allowlist. Instructions can be ignored; an absent tool cannot be called.

```
modes/                  ← this package (the repo root manifest points here)
├── index.ts            the extension: modes, guards, switches, drift audit
├── config.json         the shipped profile (order, keybinding, scopes)
├── prompts/            one system-prompt contract per mode
├── tsconfig.json       typecheck only; pi loads the .ts itself
├── prepare-types.sh    links the pi release's types into node_modules
├── selftest.mjs        52 assertions against the real extension, no pi needed
└── check.sh            tsc + selftest
```

## Install

```bash
pi install <this repo>      # or: pi -e <this repo> for one session, no settings change
```

The repo root `package.json` declares `./modes/index.ts` under the `pi` manifest, so the
modes are what an install gives you — the V-model material in the same repo is not part of
the install (see [Optional: the V-model](../README.md#optional-the-v-model-discipline)).
`pi update --extensions` moves a git install to the latest ref.

This package is independent of any workflow that uses it. It knows about modes, not about
what you do in them.

## The modes

| mode | writes | shell | what it is for |
| --- | --- | --- | --- |
| `oracle` | nothing in the repo | read-only + execute-class | reading, audits, evidence — the default for a fresh session |
| `plan` | `docs/**` and `ledger.md` only | read-only + execute-class | producing a written plan, not a conversation |
| `build` | source, never the test surface | unrestricted | implementing |
| `yolo` | anything | unrestricted | experiments; not a delivery mode |
| `forge` | anything but the machinery | unrestricted | autonomous task execution — claim, test-first, reviewed handoff |

Keys: `alt+a` cycles, `Ctrl+1..5` jump straight to a mode, `Ctrl+Shift+M` toggles
oracle ↔ build. (Not `Tab` — that must stay autocomplete-accept.) Commands: `/mode` opens
a menu, `/mode <name>` switches, `--agent-mode <name>` starts a session already in one.
The mode persists per session and is restored on resume; a brand-new session enters
`config.default`.

### `forge` — spec-first work, with the exception it needs

`forge` is for autonomous work that has to be **traceable**: it runs the intake pipeline instead of
writing code and describing it afterwards.

```text
objective → spec (specs/NNN-<slug>/) → Gate A (human ratifies) → numbered tasks T001…
          → build each (tests run by the gate) → review each → one reviewed PR
```

The pieces: the `forge` skills (clarify, spec-authoring, decompose), the role contracts (`architect`,
`builder`, `spec-reviewer`, `disposition`), and **`forge-gate`** — the deterministic tier that
scaffolds the spec, runs the nine invariants, refuses a ratification off a TTY, executes each task's
`dod_tests` itself, checks a task's commit against its declared `scope`, and refuses to open the PR
while any of that is missing. Nothing is "done" because an agent said so.

It is the only mode whose prompt contract alters a rule that applies everywhere else, so the terms
are explicit:

- **Commits.** Only on a branch named **`forge/<slug>`**, only after `ratify` has landed and
  `analyze` passes (`claim` refuses otherwise), and push/PR only through `forge-gate finish`. Never
  `main`, never a tag, no amend, no force-push.
- **Review.** Per task, the correctness lane on that task's diff; before the PR, both lanes plus
  `disposition` on the whole branch. In a forge harness checkout the harness owns PR review, so the
  session dispatches none.

The gate is the coarse belt. OS-level confinement (gondolin's mounts) is the fine one, and the
worktree plus the repo's git hooks remain the boundary that actually binds a commit.

## Overrides

The package ships a profile that has to be true everywhere, so it carries no model ids and
no provider: a package cannot know which providers you have. Configure your own without
editing inside the package — `pi update` would overwrite it.

| precedence | file | scope |
| --- | --- | --- |
| 1 (lowest) | `config.json` in this package | the shipped profile |
| 2 | `~/.pi/agent/agent-modes.json` | you, every project |
| 3 | `<repo>/.pi/agent-modes.json` | this project, committable |
| 4 (highest) | `$PI_AGENT_MODES_CONFIG` | explicit; CI and the selftest |

Each file is merged **per mode and per key**, so one line gives a mode a model without
restating its tools, scopes, or prompt:

```json
{ "provider": "anthropic", "modes": { "plan": { "model": "claude-sonnet-4-5" }, "build": { "model": "claude-sonnet-4-5" } } }
```

A model id may also carry its provider (`"model": "anthropic/claude-sonnet-4-5"`). If the
id is not available in your install, the switch is kept and a warning says where to set it
— the session does not lose its mode.

## What each layer enforces

| layer | mechanism | cannot be bypassed by |
| --- | --- | --- |
| tool presence | `dropTools` / `tools` → `setActiveTools` | a model can't call a tool absent from its schema |
| write scope | `writeScope` / `writeDeny` on `write`/`edit` `input.path` | prompt injection naming a path |
| shell policy | `bash: none\|safe\|all` + read-only allowlist | "just run the tests" in a read-only mode |
| model per mode | `model` in the mode, applied on switch | forgetting to switch models too |
| prompt contract | `prompts/<mode>.md` appended to the system prompt | (advisory; keep it aligned with the rest) |
| drift audit | tree snapshot around allowed `bash`, appended to the result | a command that quietly rewrites tracked files |

## config.json

Keys per mode:

| key | meaning |
| --- | --- |
| `model` | model id applied when entering the mode |
| `tools` | tools the mode guarantees |
| `dropTools` | removed even when `keepExtensions` kept them (e.g. `edit`, `write`) |
| `writeScope` | repo-relative path prefixes it may write; `[]` = none, omitted = any |
| `writeDeny` | prefixes it may never write, even inside `writeScope` |
| `writeDenyReason` | the sentence shown when `writeDeny` refuses a write; defaults to the frozen-test-surface wording, so a mode whose deny list means something else (machinery, agent config) says what it actually protects |
| `bash` | `none`, `safe` (read-only + execute-class allowlist), `all` |
| `keepExtensions` | keep whatever tools were already active (extension tools included) |
| `promptFile` | system-prompt contract appended for the mode |

Top level: `provider` (optional), `default` (mode for a fresh session), `order` (cycle
order), `cycleKey`.

**`writeScope`/`writeDeny` in the shipped `config.json` are a starting point, not a law.**
They assume a Python-ish repository (`tests/`, `conftest.py`, `pyproject.toml`). Set them
for the repository you are working in — from `<repo>/.pi/agent-modes.json`, which you can
commit. A path prefix matches the file itself or anything under it, so `docs` does not
cover `docs.md`; list exact filenames as exact filenames.

## Verify

```bash
node selftest.mjs      # 52 assertions, no pi required
./check.sh             # tsc + the selftest
```

`selftest.mjs` imports `index.ts` directly (Node ≥ 23 strips types) and drives
`session_start` / `tool_call` / `tool_result` with a fake extension API and a throwaway git
repo. It asserts the refusals by message, the allowed/refused command lists, the override
precedence, and the drift audit end to end.

## Limits, stated

- **Path scoping covers `write`/`edit` tool calls, not shell redirection.** In a `safe`
  shell the redirect is refused anyway; in `all` it is not. A mode that must be
  structurally unable to write needs `bash: "safe"` or `"none"`.
- **The audit is report-only.** It names the tracked files a command changed and raises a
  toast; nothing is reverted.
- **`keepExtensions: true` includes every extension tool**, including ones that write (a
  skill manager, an MCP filesystem server). Set `keepExtensions: false` if that matters
  more than context.
- **A mode is not a sandbox.** It cannot stop a process the model starts from writing
  wherever that process has permission to write, and it does not confine the session to a
  directory. It is a capability profile for the tools pi itself mediates.
