---
description: Two-model code review — correctness and quality lanes in parallel, merged into one SEV1-SEV4 table
argument-hint: "[paths or scope]"
---
Use the `code-review-swarm` skill for this request.

Scope: ${@:-the staged diff, or `git diff main...HEAD` when nothing is staged}

Follow the skill's procedure exactly: dispatch both lanes in parallel with the `subagent`
tool (`agentScope: "user"`), dedupe on site rather than on wording, re-normalise severity,
and report the single numbered `# | SEV | LOCATION | FINDING | TRIGGER | LENS | CONF` table with a
one-line header naming the two models and the counts per SEV.

Do not apply fixes. Do not modify the reviewed code.
