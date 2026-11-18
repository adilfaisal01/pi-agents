# Changelog

## [0.1.1] - 2026-11-18

- **Publishing moved to GitHub Actions.** `.github/workflows/publish.yml` publishes on a
  `v*` tag push, using OIDC trusted publishing when the `NPM_TOKEN` secret is unset and a
  granular token when it is set. Actions are pinned to commit SHAs; the job refuses a tag
  that disagrees with `package.json` and skips a version already on the registry.
- **The model-pin check no longer requires a model registry.** `code-review-swarm`'s
  selftest reports each lane's pin as `skip` on a runner without `pi`, instead of failing —
  a skip, not a pass, so a real typo still fails. `pi` is now required only for `--live`.
- Publishing the package now runs the full check first (`prepublishOnly` →
  `scripts/check-package.sh`): manifest, packed tarball, and all five suites.

## [0.1.0] - 2026-11-18

First published version, as one package holding the five tools that used to be separate
repositories.

- **Agent modes** (`v-model-agents/modes`): `oracle` / `plan` / `build` / `yolo`, each with
  its own tool set, shell policy, write scope and prompt contract. Ships no model ids; set
  them in `~/.pi/agent/agent-modes.json`.
- **Code review swarm** (`code-review-swarm`): two lanes on two models, one SEV1–SEV4
  table, `/review` template, per-lane checkouts via `review-lanes`.
- **Subagent tool** (`pi-subagent`): isolated child `pi` processes with per-agent model
  pins, a write-scope post-check, and — new in this release — `pi.agents` in the package
  manifest, so one package can ship an extension and its agent definitions.
- **Review gate** (`review-gate`): `swarm-gate` turns the two lanes into an exit code, with
  a loop guard and a round budget. 72 stub-lane cases, no model calls.
- **Lane provisioning** (`review-lanes`): a worktree at a commit, plus an assertion that the
  package resolved from inside it.

`swarm-gate` and `review-lanes` are installed as `bin` entries. Both need `python3` (the
gate) or `git` (the lanes), and bash.
