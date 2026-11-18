#!/usr/bin/env bash
# Self-test for the two review lanes.
#
#   scripts/selftest.sh          static checks only, no model calls
#   scripts/selftest.sh --live   also dispatch both lanes at the fixture
#
# Exit codes: 0 pass, 1 fail, 2 usage.

set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
LANES=(review-correctness review-quality)
FAILED=0
# The pin checks are shared with install.sh, so the two cannot disagree on a model id.
. "$ROOT/scripts/check-models.sh"

usage() {
	printf 'usage: %s [--live] [--lane <name>]\n' "${0##*/}" >&2
	exit 2
}

LIVE=0
ONLY_LANE=""
while [ $# -gt 0 ]; do
	case $1 in
		--live) LIVE=1 ;;
		--lane)
			shift
			[ $# -gt 0 ] || usage
			ONLY_LANE=$1
			;;
		-h | --help) usage ;;
		*) printf 'unknown argument: %s\n' "$1" >&2; usage ;;
	esac
	shift
done

pass() { printf 'pass  %s\n' "$1"; }
fail() {
	printf 'FAIL  %s\n' "$1"
	FAILED=1
}

# Frontmatter value: everything between the first pair of --- lines.
frontmatter_field() {
	awk -v key="$2" '
		BEGIN { fence = 0 }
		/^---[[:space:]]*$/ { fence++; next }
		fence == 1 && index($0, key ":") == 1 {
			sub("^" key ":[[:space:]]*", "")
			print
			exit
		}
	' "$1"
}

agent_body() {
	awk 'BEGIN { fence = 0 } /^---[[:space:]]*$/ { fence++; next } fence >= 2' "$1"
}

## Static checks ---------------------------------------------------------------

check_static() {
	local file name desc model tools body wscope models=()
	for lane in "${LANES[@]}"; do
		file="$ROOT/agents/$lane.md"
		if [ ! -f "$file" ]; then
			fail "$lane: agents/$lane.md missing"
			continue
		fi

		name=$(frontmatter_field "$file" name)
		desc=$(frontmatter_field "$file" description)
		model=$(lane_model "$file")
		tools=$(frontmatter_field "$file" tools)

		[ "$name" = "$lane" ] && pass "$lane: frontmatter name" || fail "$lane: frontmatter name is '$name'"
		[ -n "$desc" ] && pass "$lane: frontmatter description" || fail "$lane: no description"
		[ -n "$model" ] && pass "$lane: model $model" || fail "$lane: no model pinned"

		if [ -n "$model" ]; then
			models+=("$(lane_model_lookup "$model")")
			# The registry is the *operator's*: a CI runner or a fresh clone has no
			# providers configured, so "unresolvable here" is not a defect. A pin this
			# install HAS but does not know is a defect, and still fails.
			if [ "${PI_MODEL_CHECK:-}" = "skip" ]; then
				printf 'skip  %s: model %s not checked (PI_MODEL_CHECK=skip)\n' "$lane" "$model"
			elif ! command -v pi >/dev/null 2>&1; then
				printf 'skip  %s: model %s not checked (no pi on PATH)\n' "$lane" "$model"
			elif model_resolves "$model"; then
				pass "$lane: $model resolves"
			else
				fail "$lane: $model not in the model registry"
			fi
		fi

		case ",$tools," in
			*,write,* | *,edit,*) fail "$lane: tools allow writing ($tools)" ;;
			*,read,*) pass "$lane: read-only toolset" ;;
			*) fail "$lane: no read tool declared ($tools)" ;;
		esac

		body=$(agent_body "$file")
		case $body in
			*"| ID | SEV |"* | *"|ID|SEV|"*) pass "$lane: output contract present" ;;
			*) fail "$lane: output contract (| ID | SEV | table) not stated" ;;
		esac

		# The dispatcher's write-scope post-check returns early when this field is absent
		# (`if (!agent.writeScope?.length) return undefined`), so a lane without it is
		# caught by nothing at all when its shell writes into the tree.
		wscope=$(frontmatter_field "$file" write_scope)
		if [ -n "$wscope" ]; then
			pass "$lane: write_scope ($wscope)"
		else
			fail "$lane: no write_scope — the write-scope post-check is inert"
		fi

		# Both lanes carry a trigger: it is the only part of a finding that can be executed,
		# and the merge keeps it. A lane without the column produces rows the table drops.
		case $body in
			*TRIGGER*) pass "$lane: TRIGGER column" ;;
			*) fail "$lane: output contract has no TRIGGER column" ;;
		esac
	done

	if [ "${#models[@]}" -eq 2 ]; then
		single_model_warning "${models[0]}" "${models[1]}" || true
	fi

	skill="$ROOT/skills/code-review-swarm/SKILL.md"
	if [ -f "$skill" ] && [ -n "$(frontmatter_field "$skill" name)" ] && [ -n "$(frontmatter_field "$skill" description)" ]; then
		pass "skill: frontmatter"
	else
		fail "skill: skills/code-review-swarm/SKILL.md missing or unfrontmattered"
	fi

	tpl="$ROOT/prompts/review.md"
	if [ -f "$tpl" ] && [ -n "$(frontmatter_field "$tpl" description)" ]; then
		pass "template: /review frontmatter"
	else
		fail "template: prompts/review.md missing or has no description"
	fi
	if grep -qF '${@:-' "$tpl" 2>/dev/null; then
		pass "template: no-argument default (staged diff)"
	else
		fail "template: /review has no \${@:-…} default scope"
	fi
	if grep -qF 'code-review-swarm' "$tpl" 2>/dev/null; then
		pass "template: names the skill it drives"
	else
		fail "template: /review does not name the code-review-swarm skill"
	fi

	# The merged column set is stated in three files. A column added in one and not the
	# others is a contract the lanes never see, and nothing in a run reports it.
	local cols='# | SEV | LOCATION | FINDING | TRIGGER | LENS | CONF' stated
	for stated in "$skill" "$ROOT/README.md" "$tpl"; do
		if grep -qF "$cols" "$stated" 2>/dev/null; then
			pass "column set: ${stated#"$ROOT"/}"
		else
			fail "column set: ${stated#"$ROOT"/} does not state '$cols'"
		fi
	done

	# The model is the agents' frontmatter and nowhere else. A copy in the skill drifts
	# silently — and the only artifact that reports the wrong model is the review itself.
	if grep -qF 'Default model' "$skill" 2>/dev/null; then
		fail "skill: states a default model — read model: from the agent file"
	else
		pass "skill: no duplicated default model"
	fi

	# lane-prepare.sh is the piece that gives each lane its own checkout; it must at least
	# parse, since a broken one silently downgrades every review to a shared tree.
	if [ -f "$ROOT/scripts/lane-prepare.sh" ] && bash -n "$ROOT/scripts/lane-prepare.sh" 2>/dev/null; then
		pass "scripts/lane-prepare.sh parses"
	else
		fail "scripts/lane-prepare.sh missing or does not parse"
	fi

	if command -v node >/dev/null 2>&1; then
		if node -e '
			const fs = require("fs"), path = require("path");
			const root = process.argv[1];
			const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf8"));
			const pi = pkg.pi || {};
			const need = ["skills", "prompts"];
			for (const k of need) {
				if (!Array.isArray(pi[k]) || pi[k].length === 0) throw new Error(`pi.${k} not declared`);
				for (const rel of pi[k]) {
					const p = path.join(root, rel);
					if (!fs.existsSync(p)) throw new Error(`pi.${k} -> ${rel} does not exist`);
				}
			}
			if (!(pkg.keywords || []).includes("pi-package")) throw new Error("missing pi-package keyword");
		' "$ROOT" 2>/dev/null; then
			pass "package.json: manifest paths and pi-package keyword"
		else
			fail "package.json: manifest paths, pi-package keyword, or JSON invalid"
		fi
	else
		printf 'skip  package.json: node not on PATH\n'
	fi
}

## Live checks ----------------------------------------------------------------

run_lane() {
	local lane=$1 model=$2 out=$3
	local body prompt
	body=$(agent_body "$ROOT/agents/$lane.md")
	prompt=$(cat <<'PROMPT'
Review tests/fixture/buggy.py in this repository. Follow the output contract in
your system prompt exactly: one markdown table with a `| ID | SEV | LOCATION |`
header, SEV1-SEV4, every row carrying `path:line (symbol)`, then a COVERAGE line.
Do not apply fixes.
PROMPT
)
	# --append-system-prompt keeps the lane's own lens and contract in force, so the
	# live path measures the same thing the agent file does.
	printf '%s\n' "$body" >"$out.body"
	printf '%s\n' "$prompt" >"$out.prompt"

	(
		cd "${LANE_CWD:-$ROOT}" || exit 1
		pi -p --no-session -ne \
			--model "$model" \
			--tools read,grep,find,ls,bash \
			--append-system-prompt "$out.body" \
			"$(cat "$out.prompt")" >"$out" 2>"$out.err"
	) || return 1
	return 0
}

assert_contract() {
	local lane=$1 out=$2
	if grep -Eq '^\|[[:space:]]*ID[[:space:]]*\|[[:space:]]*SEV' "$out"; then
		pass "$lane: table header"
	else
		fail "$lane: no | ID | SEV | table header in output"
	fi

	local rows
	rows=$(grep -Ec '^\|[[:space:]]*[CQ][0-9]+[[:space:]]*\|' "$out")
	if [ "${rows:-0}" -ge 1 ]; then
		pass "$lane: $rows finding row(s)"
	else
		fail "$lane: no finding rows (the fixture has 8)"
	fi

	if grep -Eq '^COVERAGE:' "$out"; then
		pass "$lane: COVERAGE line"
	else
		fail "$lane: no COVERAGE line"
	fi

	# The static check proves the contract states TRIGGER; this proves the model emits it.
	if grep -Eq '^\|.*TRIGGER' "$out"; then
		pass "$lane: TRIGGER column emitted"
	else
		fail "$lane: table has no TRIGGER column (contract not honoured)"
	fi

	if grep -q 'buggy.py' "$out"; then
		pass "$lane: cited the fixture path"
	else
		fail "$lane: no finding cites tests/fixture/buggy.py"
	fi
}

check_live() {
	local outdir
	outdir=$(mktemp -d "${TMPDIR:-/tmp}/crswarm.XXXXXX")
	printf 'live  dispatching 2 lanes, transcripts in %s\n' "$outdir"

	local pids=() lanes=()
	for lane in "${LANES[@]}"; do
		if [ -n "$ONLY_LANE" ] && [ "$lane" != "$ONLY_LANE" ]; then
			continue
		fi
		local model
		model=$(lane_model "$ROOT/agents/$lane.md")
		if [ -z "$model" ]; then
			fail "$lane: cannot dispatch without a model"
			continue
		fi
		run_lane "$lane" "$model" "$outdir/$lane.md" &
		pids+=($!)
		lanes+=("$lane")
	done

	local i=0
	for lane in "${lanes[@]}"; do
		if wait "${pids[$i]}"; then
			pass "$lane: exited 0"
			assert_contract "$lane" "$outdir/$lane.md"
		else
			fail "$lane: dispatch failed (see $outdir/$lane.err)"
			tail -3 "$outdir/$lane.err" 2>/dev/null | sed 's/^/      /'
		fi
		i=$((i + 1))
	done
}

## Main -----------------------------------------------------------------------

# `--live` spawns pi children, so it needs pi. The static checks do not: a clone or a CI
# runner without pi can still verify the lane contracts.
if [ "$LIVE" -eq 1 ] && ! command -v pi >/dev/null 2>&1; then
	printf 'FAIL  pi not on PATH, and --live dispatches the lanes\n' >&2
	exit 1
fi

check_static

if [ "$LIVE" -eq 1 ]; then
	check_live
fi

if [ "$FAILED" -eq 0 ]; then
	printf '\nall checks passed\n'
	exit 0
fi
printf '\nchecks failed\n'
exit 1
