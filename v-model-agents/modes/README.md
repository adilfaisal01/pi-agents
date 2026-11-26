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
├── selftest.mjs        assertions against the real extension, no pi needed
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

| mode | writes | shell | remote | what it is for |
| --- | --- | --- | --- | --- |
| `oracle` | nothing in the repo | read-only + execute-class + `gh` reads | read | reading, audits, evidence — the default for a fresh session |
| `plan` | `docs/**` only — the plan itself is the `todo` list | read-only + execute-class + `gh` reads | read | producing a plan as dated todo items, not a prose answer |
| `build` | source, never the test surface | unrestricted | read and write | implementing |
| `yolo` | anything | unrestricted | read and write | experiments; not a delivery mode |
| `forge` | anything but the machinery | unrestricted | read and write, push/PR only through `forge-gate finish` | autonomous task execution — claim, test-first, reviewed handoff |

The remote is part of every mode's tool set: `mcp__github` (one namespace proxy per server,
so the operation name is what the guard sees) plus the `gh` CLI on the read subcommands of a
read-only shell. A mode that may only read it declares `mcpReadOnly: ["github"]` and the
tool-call guard refuses create/push/comment/merge by operation name.

Keys: `alt+a` cycles, `Ctrl+1..5` jump straight to a mode, `Ctrl+Shift+M` toggles
oracle ↔ build. (Not `Tab` — that must stay autocomplete-accept.) Commands: `/mode` opens
a menu, `/mode <name>` switches, `--agent-mode <name>` starts a session already in one.
The mode persists per session and is restored on resume; a brand-new session enters
`config.default`.

## The plan is the todo list

`plan` records a plan as `todo` items — one per step, subject dated (`YYYY-MM-DD · step`),
`metadata.added` carrying the ISO timestamp, and the check each step must pass in its
`description`. No `ledger.md`, no `plan.md`: an executing agent already reads the todo list,
so a file copy is state that has to be reconciled, and the one state that is never stale is
the list the agent is already looking at.

`build` and `yolo` therefore close the ledger as they go: an item goes to
`status: "completed"` in the same turn as the verification it names, with `metadata.done`
set and `added` left alone. Batching closures to the end of a run turns the ledger back into
a recollection, and a failed check keeps its item `in_progress` with the blocker added as a
new item — writing the code is not completing the step.

`todo` is listed in every mode's `tools`, so the ledger survives a switch: the list is one
piece of state, not one per mode.

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

- **Commits.** Only in the worktrees **`forge-gate claim` creates** (`<repo>.forge/<slug>/` on
  `forge/<slug>`, and `<repo>.forge/<slug>/<T00N>/` on `forge/<slug>-<T00N>`), only after `ratify`
  has landed and `analyze` passes, and push/PR only through `forge-gate finish`. The user's checkout
  is never the place work happens. Never `main`, never a tag, no amend, no force-push.
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
| shell policy | `bash: none\|safe\|all` + read-only allowlist (the `gh` read subcommands included) | "just run the tests" in a read-only mode |
| remote writes | `mcpReadOnly` → `tool_call` on the namespace proxy, the direct tool, or a resolved `mcp` gateway target | a write the proxy also carries — the guard is what separates reading a PR's diff from merging it |
| model per mode | `model` in the mode, applied on switch | forgetting to switch models too |
| prompt contract | `prompts/<mode>.md` in the `<agent-mode>` system-prompt section | (advisory; keep it aligned with the rest) |
| switch notice | a `customType: "agent-modes"` message stating the new permissions and the tools gained/lost | (advisory; but a model that ignores it walks into a refusal) |
| drift audit | tree snapshot around allowed `bash`, appended to the result | a command that quietly rewrites tracked files |

## What the model is told when the mode changes

A switch is enforced by the harness — the tool schema changes, the guards refuse — but an
enforced switch is still an unexplained one unless the model is told. Two mechanisms carry that:

1. **The prompt contract is a tagged section, not a rewritten prompt.** `prompts/<mode>.md` goes
   into the `<agent-mode>` system-prompt section. Pi diffs the sections the model already has
   against the ones requested and appends one system message patching only what changed — so a
   switch reaches the model as "the `<agent-mode>` section and the tool list changed", its
   cached prefix survives, and pi's own `toolsRemoved` declaration (`edit`, `write`) stays in the
   transcript. Returning a whole `systemPrompt` instead would replace the prompt for the run:
   a full cache miss on every switch, and every other system message dropped, `toolsRemoved`
   included — the model would lose its write tools without being told.
2. **The switch itself is a message.** Entering a mode writes one `customType: "agent-modes"`
   entry stating the mode it came from and went to, the write and shell policy in that mode's
   own words, the tools gained and lost, the model, and the fact that earlier statements about
   its permissions are superseded. `steer` mid-run (the new tool set is already live, the
   running prompt is not); a plain message when idle, which persists immediately and starts no
   turn. A fresh session announces nothing — there is nothing to supersede. A **resume** that
   lands in a different mode than the transcript last knew (a `--agent-mode` flag beating the
   persisted mode) says so as `Mode restored:`, because that switch happened before this
   process existed.

Switches are also serialized: `pi.setModel` resolves only when a provider swap lands, and two
keystrokes inside that window used to interleave two modes' tools, entries and model requests —
the slower swap winning the model while the later switch owned the mode.

Refusals name the way out the same way: they point at the real cycle key
(`cycleKey`, or `/mode <name>`) rather than a key that does not exist, because the model can
only ask the user to press it.

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
| `bash` | `none`, `safe` (read-only + execute-class allowlist, `gh` reads included), `all` |
| `mcpReadOnly` | MCP servers this mode may only read. A call is refused unless its operation starts with `get_`/`list_`/`search_`/`read_`/`view_`/`describe_`/`inspect_` — fail-closed, so a write tool a server gains later is refused without editing this file |
| `keepExtensions` | keep whatever tools were already active (extension tools included) |
| `promptFile` | the mode's contract, published in the `<agent-mode>` system-prompt section |

Top level: `provider` (optional), `default` (mode for a fresh session), `order` (cycle
order), `cycleKey`.

**`writeScope`/`writeDeny` in the shipped `config.json` are a starting point, not a law.**
They assume a Python-ish repository (`tests/`, `conftest.py`, `pyproject.toml`). Set them
for the repository you are working in — from `<repo>/.pi/agent-modes.json`, which you can
commit. A path prefix matches the file itself or anything under it, so `docs` does not
cover `docs.md`; list exact filenames as exact filenames.

## Verify

```bash
node selftest.mjs      # the assertions, no pi required
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
- **A read-only MCP server is a guard on an operation name, not an absent capability.**
  `mcpReadOnly` refuses the call at `tool_call`; the proxy still carries the server's whole
  surface, so what holds is the guard, exactly as for any extension tool. The `mcp` gateway
  is resolved against the live registry, which catches the bare (`create_issue`) and
  server-prefixed (`github_create_issue`) forms as well as the canonical one — but a target
  that names no registered tool cannot be resolved, so it is not gated. Calling the server's
  own proxy (`mcp__github`) keeps the operation visible to the guard.
- **A mode is not a sandbox.** It cannot stop a process the model starts from writing
  wherever that process has permission to write, and it does not confine the session to a
  directory. It is a capability profile for the tools pi itself mediates.
- **A mid-run switch changes tools before it changes the prompt.** The active tool set is
  applied per request, but a run's prompt options are fixed when it starts, so a switch in the
  middle of a run reaches the model through the notice and the tool declarations, and its
  `<agent-mode>` section only changes on the next turn. Providers that accept system messages
  mid-conversation get the section patch in place; others get the replayed prompt, which is one
  cache miss per switch.
- **The notice is not free.** One short message per switch stays in the transcript for the rest
  of the session, and is re-sent with it.
