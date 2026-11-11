# 01 — Roles and capability profiles

A role is a **capability profile**: what it may write, how wide its context is, and what
artifact it must hand back. Two roles that differ only in prompt tone are one role.

There are three, and only one of them is a session you sit in:

| role | writes | shell | runs where | produces |
| --- | --- | --- | --- | --- |
| `plan` | `ledger.md` only | read-only + execute-class | your session | R/D rows, lane partition, `sources`, test briefs |
| `sysdv` | `tests/**` + test config only | read + execute (it must see red) | `pi` child in a worktree at the **pre-implementation commit** | locked tests + the recorded red run |
| `build` | the row's `sources`, **never** the lock surface | unrestricted | `pi` child in a worktree at the **pin** | implementation to green |

Two properties matter more than the table:

1. **The lanes are processes, not modes.** `sysdv` and `build` are spawned by
   `gate/wave.sh`, each with its own worktree, its own context, and its own model. A
   process cannot see the plan conversation, which is exactly what must not reach the
   test author.
2. **Your session is not one of them.** You write the ledger (`plan`), and you run the
   machinery. You do not edit source during a wave, and you do not write tests for the
   row.

## Why the parent is not enforced

The tool-stripping and path-scoping that used to live in this repo is now its own pi
package, [`modes/`](../modes/README.md) — it is what `pi install` on this repo gives you
(`DECISIONS.md` #17). It still works, and it is still the wrong boundary for *this*
discipline: the
promise worth enforcing is *the lane cannot write outside its row*, and that promise is
held where it costs nothing to enforce — in the script that owns the process, after the
process exits. The parent session is advised by this document and by the skill; if you
want a wall on yourself, either install the modes package or start the session with a
tool list:

```bash
pi --tools read,grep,find,ls,bash      # no write, no edit, no shell writes of your own
```

That is a launch flag, not a stored mode, which is the point: the capability profile is
chosen when the work is chosen rather than remembered across sessions.

## Structural enforcement, not instructions

"Assume tool permissions are not perfectly enforceable" remains the correct posture.
Cheapest layer first:

| layer | what it stops | where |
| --- | --- | --- |
| tool list | the lane never sees a tool it was not granted | `--tools` on the spawned `pi` |
| worktree | edits to the implementation cannot happen where it does not exist | `git worktree add` at the pre-implementation commit |
| post-check | a lane that wrote outside its scope | `git status --porcelain` in the worktree, filtered, on return |
| red check | a test that would pass if the behaviour were wrong (or absent) | `./gate/run-tests.sh` at the pre-implementation commit |
| scope check | a build lane editing the thing it must satisfy | the row's `sources` from the ledger, enforced per lane |
| lock + pin | a suite that was silently weakened after the freeze | `gate/lock-check.sh <pin>` |

The last one is the one that survives the wave: everything else is checked at the moment
of the run, and the pin is checked afterwards, from any checkout, by anyone.

## Refusal messages are part of the contract

A refusal says what was refused, why, and the legal alternative. Predictable text is what
makes a gate reviewable:

```
wave: REFUSED — the frozen surface moved (see /tmp/vmodel-wave-xxxx/R2.lock.log)
```

```
R3	failed	wrote outside scope: src/app.py (see /tmp/vmodel-wave-xxxx/R3.log)
```

```
wave: REFUSED — the composed tree is not the union of the lanes' scoped paths:
  tests/test_tracking.py is claimed by R1 and R2
```

```
wave: REFUSED — the suite is GREEN at 4f2c1ab — vacuous lane, or it tests something
that already exists
```

## What a role must not be

A role is not a personality. If two roles differ only in prompt tone they are one role.
If they differ in *what they can touch* and *what artifact they must hand back*, they are
real and worth their own process.
