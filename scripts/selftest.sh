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
	local file name desc model tools body prov want_id
	for lane in "${LANES[@]}"; do
		file="$ROOT/agents/$lane.md"
		if [ ! -f "$file" ]; then
			fail "$lane: agents/$lane.md missing"
			continue
		fi

		name=$(frontmatter_field "$file" name)
		desc=$(frontmatter_field "$file" description)
		model=$(frontmatter_field "$file" model)
		tools=$(frontmatter_field "$file" tools)

		[ "$name" = "$lane" ] && pass "$lane: frontmatter name" || fail "$lane: frontmatter name is '$name'"
		[ -n "$desc" ] && pass "$lane: frontmatter description" || fail "$lane: no description"
		[ -n "$model" ] && pass "$lane: model $model" || fail "$lane: no model pinned"

		if [ -n "$model" ]; then
			# Exact match on both columns: --list-models fuzzy-matches, so a substring
			# test would pass on a lookalike (kimi-k2.6 vs kimi-k3) and hide a typo.
			prov=${model%%/*}
			if [ "$prov" = "$model" ]; then
				prov=""
				want_id=$model
			else
				want_id=${model#*/}
			fi
			if pi --list-models "$model" 2>/dev/null | awk -v p="$prov" -v m="$want_id" '
				NR > 1 && $2 == m && (p == "" || $1 == p) { found = 1 }
				END { exit !found }
			'; then
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
	done

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
		cd "$ROOT" || exit 1
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
		model=$(frontmatter_field "$ROOT/agents/$lane.md" model)
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

command -v pi >/dev/null 2>&1 || {
	printf 'FAIL  pi not on PATH\n' >&2
	exit 1
}

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
