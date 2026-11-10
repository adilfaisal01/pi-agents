# 01 — Modes, roles, and capability profiles

A mode is a **capability profile**, not a role in a conversation. Roles are defined by
what they may write and what they must produce; the mode enforces the first, the prompt
and the ledger enforce the second.

## Profiles

| role | writes | shell | model | produces |
| --- | --- | --- | --- | --- |
| `oracle` | nothing in the repo | read-only + execute-class (test/lint/build) | strong reader | evidence, audits rows it did not produce |
| `plan` | ledger/spec paths only | read-only + execute-class | planner | R/D rows, lane partition, test briefs |
| `sysdv` | `tests/**` + test config only | read + execute (needs red-first) | *different from build* | locked tests + red record |
| `build` | row's source paths, **never** the lock surface | unrestricted | builder | implementation to green |
| `yolo` | anything | unrestricted | — | unconstrained experiments; not a delivery mode |

Two properties matter more than the table:

1. **`oracle` is the default posture.** A fresh session starts read-only toward the
   repo. Writing is a deliberate act, not the resting state.
2. **`sysdv` is a subagent, not a mode.** It runs as a separate process with its own
   context and its own model, so it never sees the build conversation. A mode switch
   shares the transcript, which is exactly what must not happen to the test author.

## Structural enforcement, not instructions

Tool lists alone are not enough — "assume tool permissions are not perfectly
enforceable" is the correct posture. Layers, cheapest first:

| layer | what it stops | where |
| --- | --- | --- |
| tool removal | the model never sees `edit`/`write` in its schema | mode config (`dropTools`) |
| path scope | writes outside the role's paths | `tool_call` guard on `write`/`edit` `input.path` |
| worktree | edits to the implementation cannot happen where it does not exist | `git worktree add` at the pre-implementation commit |
| hash pin | a suite that was silently weakened | `gate/lock-check.sh` against the freeze sha |
| post-check | a subagent that wrote outside its scope | `git -C <worktree> diff --name-only` on return |

Path scoping is the piece most setups lack. It is also the cheapest: `write`/`edit`
carry `{ path }`, so it is a prefix check plus a stable refusal message.

## Refusal messages are part of the contract

A refusal must say what was refused, why, and the legal alternative. Predictable text is
what makes a gate reviewable:

```
[build] refused: write to 'tests/test_tracking.py' — the frozen test surface
is locked at 4f2c1ab. Changing a test requires an amendment commit that states
the spec changed; a build lane never edits a test.
```

```
[sysdv] refused: write to 'src/shinro/...' — sysdv may write only tests/** and
test configuration. Implementation belongs to a build lane.
```

```
[oracle] refused: command changes TRACKED files — the repo is read-only here.
Nothing was reverted. Discard the output deliberately in a writing mode.
```

## What a mode must not be

A mode is not a personality. If two modes differ only in prompt tone they are one mode.
If they differ in *what they can touch* and *what artifact they must hand back*, they are
real and worth their own keybinding.
