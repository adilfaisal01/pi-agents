# Intake Spec Template

> The intake artifact for a forged change. An architect turns a fuzzy objective into this spec —
> prioritized stories, testable requirements, measurable success criteria — and then into a
> machine-parseable **Task Breakdown** that `forge-gate` validates and drives. Boilerplate, not
> framework: the schema below is the contract, and every claim in it is re-checkable by a third party
> without asking the agent anything.

## How to use this template

`forge-gate start <slug>` scaffolds this file to `specs/NNN-<slug>/spec.md` and fills the Header. The
architect (the forge-mode session, or a dispatched `architect` agent) authors the rest:

- fill every `[PLACEHOLDER]`, and wherever the objective is silent leave a
  `[NEEDS CLARIFICATION: <question>]` marker;
- resolve each marker with the `clarify` skill — `ask_user_question` in interactive mode, a flagged
  `[ASSUMED …]` in autonomous mode; the post-condition is **zero residual markers**;
- author the **Task Breakdown** with the `decompose` skill, then run `forge-gate analyze`.

Then **Gate A**: write `understanding.md` (the projection of the completed FR set beside this spec) and
have a **human** run `forge-gate ratify specs/NNN-<slug>`. Ratification binds `sha256(understanding.md)`
and appends the row that every later step reads. Agents never ratify.

Conventions: ATX headings, no emoji, **bold** for emphasis, `backticks` for ids/paths/flags.
Requirement ids are stable once assigned — never renumber; mark withdrawn items `~~FR-007~~ (withdrawn)`.

---

## Header

- **Objective:** [PLACEHOLDER — one or two sentences: the outcome wanted, in the user's words.]
- **Target Repo(s):** [PLACEHOLDER — repo slug(s), e.g. `pi-agents`. Must match `target_repos` in the Task Breakdown.]
- **Mode:** [`interactive` | `autonomous`]
- **Status:** [`draft` | `clarifying` | `ready-for-tasks` | `approved`]
- **Branch:** [`forge/<slug>` — the only branch forge mode may commit to.]

---

## User Scenarios

Prioritized user stories. **P1** = must-have for the objective to be meaningful; **P2** = important but
deferrable; **P3** = nice-to-have. Each story is an independently-testable slice (vertical, not a
horizontal layer). Story ids (`US1`, `US2`, …) are stable and referenced by tasks.

### US1 (P1) — [Story title]

[As a `<role>`, I want `<capability>`, so that `<benefit>`.]

- **Independent Test:** [What single observable behaviour proves _this story alone_ works, with nothing
  else built? This becomes (or informs) the closing task's Definition of Done.]
- **Acceptance Scenarios:**
  1. **Given** [precondition], **When** [action], **Then** [observable outcome].
  2. **Given** […], **When** […], **Then** […].
- **Edge Cases:**
  - [What happens when [boundary / empty / failure]? `[NEEDS CLARIFICATION: …]` if silent.]

---

## Requirements

Functional requirements, each phrased as an imperative the system must satisfy. Use `[NEEDS
CLARIFICATION: …]` inline wherever the objective does not pin a behaviour down. Each requirement should
be testable and trace to at least one story.

- **FR-001:** System **MUST** [specific, testable behaviour]. _(US1)_
- **FR-002:** System **MUST** [specific, testable behaviour]. _(US1)_
- **FR-003:** System **MUST** [behaviour] `[NEEDS CLARIFICATION: which auth method — session token,
OAuth, API key?]`. _(US2)_
- **FR-004:** System **SHOULD** [behaviour that is desirable but not load-bearing]. _(US2)_

> Phrasing: **MUST** for load-bearing, **SHOULD** for strong-but-optional. Avoid HOW — state _what_
> must be true, never which library/file/algorithm delivers it (see the WHAT/WHY-not-HOW discipline in
> the `decompose` skill).

---

## Success Criteria

Measurable, technology-agnostic outcomes that prove the objective is met. **No** framework, library, or
file names. Prefer numeric thresholds or directly observable outcomes. Each `SC-NNN` is referenced by
tasks and is the yardstick a human uses at the merge gate.

- **SC-001:** [Measurable outcome, e.g. "95% of submissions complete in under 2 seconds end-to-end."]
- **SC-002:** [Measurable outcome, tech-agnostic.]

> A criterion is good only if two people would agree on pass/fail by measuring, without reading the
> code. Worked examples live in the `decompose` skill.

---

## Assumptions

Decisions taken where the objective was silent. In **autonomous** mode the architect records its
best-guess answers here, each flagged for the human gate:

- `[ASSUMED · <category> · confidence:low|med]` [The assumed answer.] **Chosen because** [rationale].
  **Discarded:** [the alternatives not taken]. _(propagated to FR-00X / SC-00X)_
- [Plain assumptions the author made deliberately, without a clarification round, also go here.]

---

## Deferrals / Out of scope

The **coverage ledger**, made visible for the human Gate-A review. Every category in the coverage set
appears **exactly once**, carrying one of three dispositions, so an omission is a ratifiable decision
rather than an invisible gap. The category set is the `harness/intake-categories.json` taxonomy when the
repo has one; otherwise use the twelve clusters named in the `clarify` skill.

- **[category]** — **covered by FR-NNN** (an FR / SC / edge case exists), or
- **[category]** — **deliberately N/A — [reason]** (consciously skipped or not applicable), or
- **[category]** — **surfaced — [ref]** (a `## Clarifications` answer or a flagged `[ASSUMED …]`).

## Clarifications

Append-only log of resolved ambiguities — **one `### Round N` entry per clarify round** (one
`ask_user_question` call). Each answer is _also_ written into the live section above, with its marker
removed. The round budget bounds questions, never coverage; see the `clarify` skill.

### Round 1 — YYYY-MM-DD

- **Q (security):** [question asked] → **A:** [chosen answer]. _(propagated to FR-003, SC-002)_

---

## Task Breakdown

The **machine-parseable contract**. `forge-gate` slices the block between the sentinels below, strips the
code fence, and validates the JSON. The sentinels make extraction unambiguous even if other ` ```json `
blocks appear elsewhere in this spec. **Do not** edit the sentinel lines. There is exactly one task block
per spec, and it is the single source of truth for tasks — there is no parallel human-maintained list to
drift from.

### Field schema (per task)

| field | type | rule |
| --- | --- | --- |
| `id` | string | `^T[0-9]{3}$`; unique within this spec. The task's identity everywhere in the audit trail. |
| `title` | string | imperative one-liner. |
| `satisfies` | string[] | ≥1 entry; each matches `FR-[0-9]{3}` or a story id like `US1`. Traceability to requirements/stories. |
| `priority` | string | one of `P1`, `P2`, `P3`. |
| `depends_on` | string[] | local task ids (e.g. `["T001"]`); may be empty `[]`; the graph **MUST** be acyclic. |
| `target_repo` | string | the repo this task lands in; **MUST** be one of the top-level `target_repos`. |
| `definition_of_done` | string[] | ≥1 binary, checkable condition for **this** task, including a test that fails first then passes. |
| `success_criteria` | string[] | ≥1 measurable, technology-agnostic criterion; may reference an `SC-NNN` or state an inline threshold. |
| `scope` | string[] | ≥1 entry; each a repo-relative **glob** naming the files this task's build may touch. Normative format below (invariant 7); enforced by `forge-gate complete` against the task commit's diff. |
| `dod_tests` | string[] | ≥1 entry; each a runnable **test selector** — the mechanical Definition of Done. Normative grammar below (invariant 8); executed by `forge-gate build`, never by `analyze`. |
| `sc_evidence` | object[] | ≥1 entry; each `{"sc": N, "path": "<file>"[, "must_match": "<ERE>"][, "must_not_match": "<ERE>"]}` — `N` a **1-based index** into this task's `success_criteria`, `path` repo-relative. Bidirectional (invariant 9). |
| `verification` | string | optional but recommended: the command that proves the DoD (the red→green hook). |

`definition_of_done` and `success_criteria` are what the human reads at the breakdown sign-off. The
three machine fields (`scope`, `dod_tests`, `sc_evidence`) are what the mechanical checks enforce. Both
are required; neither substitutes for the other.

### Selector and glob formats (normative)

Invariants 7 and 8 validate **exactly** these formats; `forge-gate analyze` implements them and must
never diverge from this text.

A **scope glob** is repo-relative and fail-closed:

- non-empty; must **not** start with `/` (no absolute paths);
- must **not** contain `..` anywhere (rejects the whole `*..*` traversal class);
- characters limited to `A-Z a-z 0-9 . _ * ? [ ] / -` — no whitespace, no backslash, no `~`, no `$`, and
  no brace expansion (`{a,b}` is shell _expansion_, not pattern matching);
- examples: `src/**`, `tests/test_slugify.py`, `docs/file[0-9].md`.

A **`dod_tests` selector** is a repo-relative runnable test file, matching
`^(tests|sandbox)(/[A-Za-z0-9][A-Za-z0-9._-]*)+$` (every segment starts alphanumeric; `..`, dotfiles and
option-shaped segments are rejected). Validation is **syntactic only** in `analyze`; `forge-gate build`
executes each selector as a whole file (`timeout <T> bash <selector>`, single argv, stdin `/dev/null`).
The `::pattern` form is rejected: pattern execution is not a defined convention.

An **`sc_evidence` path** is a repo-relative file path: non-empty, not absolute, no `..`, matching
`^[A-Za-z0-9][A-Za-z0-9._/-]*$`, and matched by ≥1 of this task's `scope` globs — so the evidence the
build creates is always stageable in-scope.

`analyze` validates only that shape. **`forge-gate complete` verifies the evidence itself**: the path
must exist in the task commit's tree (`missing-from-tree`), must not be a symlink, and when the entry
carries `must_match` / `must_not_match` the committed blob must satisfy that ERE (`evidence-content-
mismatch` / `evidence-content-forbidden`). An entry with neither pattern asserts existence only and the
trail records `evidence-existence-only` as an advisory — present, but content unverified. A criterion
whose evidence never appears is not met, so the task cannot complete.

#### Matching semantics (normative, both directions)

Scope globs are matched as POSIX shell case-patterns:

- `*` crosses `/` — `src/*` matches `src/a/b.py`;
- `**` is equivalent to `*` (no globstar special-casing);
- `dir/**` does **not** match the bare `dir` entry itself;
- `?` is exactly one character; `[0-9]` classes work;
- matching is literal and case-sensitive — no expansion, no dotfile special-casing.

A scope glob is **vacuous** iff it matches the POSIX ERE `^([*?/]|\[[^]]*\])+$` — `*`, `**/*`, `[a-z]*`.
A vacuous glob declares a scope everything satisfies, so the boundary does not constrain. It is **not**
a validation error: `analyze` records a `scope-breadth-anomaly` advisory.

### Validation invariants (fail-loud, named offenders)

`forge-gate analyze` rejects the spec — loudly, no partial acceptance — unless **all** hold:

1. Every task has all required keys: `id`, `title`, `satisfies`, `priority`, `depends_on`, `target_repo`,
   `definition_of_done`, `success_criteria`, `scope`, `dod_tests`, `sc_evidence`. (`verification` optional.)
2. `id` matches `^T[0-9]{3}$` and is unique across `tasks`.
3. `priority` ∈ `{P1, P2, P3}`.
4. Every `depends_on` entry references an existing task `id`, and the graph topologically sorts (no cycles).
5. `satisfies`, `definition_of_done`, `success_criteria` are each non-empty.
6. `target_repo` ∈ top-level `target_repos`.
7. `scope` is a non-empty array; every entry a well-formed repo-relative glob per the normative format.
8. `dod_tests` is a non-empty array; every entry a syntactically valid selector per the normative grammar.
9. `sc_evidence` is a non-empty array of `{sc, path}` objects, **bidirectional**: every `success_criteria`
   index (1-based) is covered by ≥1 entry; every entry's `sc` resolves to a defined index; every `path`
   is well-formed **and** matched by ≥1 `scope` glob.

Plus **spec-level traceability**, which is not per-task: every `FR-NNN` in the prose is satisfied by ≥1
task, and every `satisfies` entry resolves to a prose `FR-NNN` / `US` id. Every rejection names the
offending id.

### The block

<!-- shinro:tasks:begin v1 -->

```json
{
  "spec_version": "forge/v1",
  "target_repos": ["pi-agents"],
  "tasks": [
    {
      "id": "T001",
      "title": "Reject specs whose Task Breakdown fails schema validation",
      "satisfies": ["FR-001", "US1"],
      "priority": "P1",
      "depends_on": [],
      "target_repo": "pi-agents",
      "definition_of_done": [
        "A failing test asserts a spec with a duplicate task id is rejected; it then passes.",
        "Validation runs all nine invariants and exits non-zero naming the offending task id."
      ],
      "success_criteria": [
        "SC-001",
        "100% of the malformed-spec fixtures are rejected with a non-zero exit and a named offending id; 0 valid fixtures are rejected."
      ],
      "scope": ["src/validator/**", "tests/fixtures/**"],
      "dod_tests": ["tests/fixtures/run.sh"],
      "sc_evidence": [
        { "sc": 1, "path": "tests/fixtures/evidence/sc1-fixture-verdicts.txt" },
        { "sc": 2, "path": "tests/fixtures/evidence/sc2-rejection-rates.txt" }
      ],
      "verification": "run forge-gate analyze against each fixture and assert exit codes"
    }
  ]
}
```

<!-- shinro:tasks:end -->
