#!/usr/bin/env bash
# wave.sh — run one V-model wave: one sysDV lane per row, in parallel, one level at a time.
#
#   ./gate/wave.sh rows <ledger>                                  # id, level, tests
#   ./gate/wave.sh sysdv --ledger <f> --level L3 --base <sha> \
#                        [--width 3] [--root <dir>] [--child <cmd>] [--dry-run]
#
# Why a script and not an agent: the ordering this enforces (worktree at the
# pre-implementation commit, tests red at that commit, nothing written outside the
# row's scope) is exactly the part that must not be left to a model's judgement.
# DECISIONS #2: scripts certify, the human judges.
#
# The level is what makes the V work bottom-up: a level-L wave freezes level-L
# verification, and nothing at a higher level is frozen until the level below it is
# red-for-the-stated-reason at its own commit. Levels (docs/02):
#
#   L3 unit · L2 component · L1 subsystem/integration · L0 system/end-to-end
#
# Waves run L3 first. Each lane is a separate `pi` process with its own worktree.
set -euo pipefail

SELF="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The agent file belongs to THE PACKAGE, not to the repo being worked on: gate/ is
# meant to be dropped into a target repo, and that repo has no pi/agents/.
AGENT_FILE="${PI_SYSDV_AGENT:-$PKG_ROOT/pi/agents/sysdv.md}"

usage() { sed -n '2,12p' "$SELF" | sed 's/^# \{0,1\}//' >&2; }
die() { printf 'wave: %s\n' "$*" >&2; exit 2; }

# --- ledger parsing --------------------------------------------------------
# The ledger is a markdown table and the column order is whatever the header says,
# so a missing column yields an empty cell rather than the whole line.
AWK_HELPERS='
	function trim(s) { gsub(/^[ \t]+|[ \t]+$/, "", s); return s }
	function cell(name) { return (name in col) ? trim($(col[name])) : "" }
	function header() {
		hdr = 1
		for (i = 1; i <= NF; i++) col[trim($i)] = i
	}
'

rows_cmd() {
	local ledger="${1:-}"
	[ -n "$ledger" ] && [ -f "$ledger" ] || die "usage: wave.sh rows <ledger>"
	awk -F'|' "$AWK_HELPERS"'
		/^\|[ ]*id[ ]*\|/ && !hdr { header(); next }
		hdr && /^\|[ ]*-+/ { next }
		hdr && /^\|/ {
			if (cell("id") == "") next
			printf "%s\t%s\t%s\n", cell("id"), cell("level"), cell("tests")
		}
	' "$ledger"
}

row_field() { # row_field <ledger> <id> <column>
	awk -F'|' -v want="$2" -v column="$3" "$AWK_HELPERS"'
		/^\|[ ]*id[ ]*\|/ && !hdr { header(); next }
		hdr && /^\|[ ]*-+/ { next }
		hdr && /^\|/ && cell("id") == want { print cell(column); exit }
	' "$1"
}

levels_cmd() { # distinct levels present, bottom-up (L3 before L0)
	local ledger="${1:-}"
	[ -n "$ledger" ] && [ -f "$ledger" ] || die "usage: wave.sh levels <ledger>"
	rows_cmd "$ledger" | cut -f2 | grep -v '^$' | sort -r | uniq
}

# --- lane policy -----------------------------------------------------------
# Paths a sysDV lane may create: tests/ plus test configuration (docs/03).
in_scope() {
	case "$1" in
	tests/* | test/* | __tests__/* | spec/*) return 0 ;;
	conftest.py | pyproject.toml | pytest.ini | tox.ini | setup.cfg) return 0 ;;
	jest.config.* | vitest.config.*) return 0 ;;
	*) return 1 ;;
	esac
}

# Caches a legitimate run produces (mirrors pi/extensions/subagent).
is_derived() {
	case "$1" in
	__pycache__/* | */__pycache__/* | *.pyc | *.pyo) return 0 ;;
	.pytest_cache/* | */.pytest_cache/* | .mypy_cache/* | */.mypy_cache/*) return 0 ;;
	.ruff_cache/* | */.ruff_cache/* | .venv/* | venv/*) return 0 ;;
	node_modules/* | */node_modules/* | *.egg-info/*) return 0 ;;
	.zig-cache/* | zig-cache/*) return 0 ;;
	*) return 1 ;;
	esac
}

# Changed paths in a worktree, one per line, minus tool state and derived caches.
changed_paths() {
	git -C "$1" status --porcelain=v1 -uall 2>/dev/null |
		sed 's/^...//' | sed 's/.* -> //' | tr -d '"' |
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			case "$p" in .*) continue ;; esac
			is_derived "$p" && continue
			printf '%s\n' "$p"
		done
}

# --- one lane --------------------------------------------------------------
run_lane() {
	local id="$1" ledger="$2" base="$3" root="$4" child="${5:-}"
	local wt="$root/$id" log="$root/$id.log"
	local requirement design interface tests body

	requirement="$(row_field "$ledger" "$id" requirement)"
	design="$(row_field "$ledger" "$id" design)"
	interface="$(row_field "$ledger" "$id" interface)"
	tests="$(row_field "$ledger" "$id" tests)"

	git worktree add -q --detach "$wt" "$base" 2>>"$log" || {
		printf '%s\tfailed\tworktree add at %s failed (see %s)\n' "$id" "${base:0:12}" "$log"
		return 1
	}
	[ -e "$wt/.git" ] || {
		printf '%s\tfailed\tworktree add reported success but %s is not a worktree\n' "$id" "$wt"
		return 1
	}

	{
		printf 'Row: %s\n\nRequirement: %s\n\nDesign: %s\n\nInterface: %s\n\n' \
			"$id" "$requirement" "$design" "$interface"
		[ -n "$tests" ] && printf 'Tests named by the ledger (the interface being locked): %s\n\n' "$tests"
		printf 'Worktree: %s\nYou are at commit %s, BEFORE the implementation exists.\n' "$wt" "$base"
	} >"$root/$id.task"

	if [ -n "$child" ]; then
		# Alternate runner: the selftest uses this to prove the orchestration with
		# no model. Contract: <child> <worktree> <task-file>.
		"$child" "$wt" "$root/$id.task" >>"$log" 2>&1 || true
	else
		body="$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$AGENT_FILE")"
		[ -n "$body" ] || {
			printf '%s\tfailed\tagent file has no body: %s\n' "$id" "$AGENT_FILE"
			return 1
		}
		(cd "$wt" && pi --mode json -p --no-session -ne \
			--tools read,grep,find,ls,bash,write,edit \
			--append-system-prompt "$body" \
			"$(cat "$root/$id.task")") >>"$log" 2>&1 || true
	fi

	# post-check 1: nothing outside the lane's scope
	local outside
	outside="$(changed_paths "$wt" | while IFS= read -r p; do in_scope "$p" || printf '%s\n' "$p"; done)"
	if [ -n "$outside" ]; then
		printf '%s\tfailed\twrote outside scope: %s (see %s)\n' \
			"$id" "$(printf '%s' "$outside" | paste -sd, -)" "$log"
		return 1
	fi

	# post-check 2: the lane must have produced a test
	if ! changed_paths "$wt" | grep -qE '^(tests|test|spec|__tests__)/'; then
		printf '%s\tfailed\tno test was created (see %s)\n' "$id" "$log"
		return 1
	fi

	# post-check 3: and it must be RED at the base commit
	if [ ! -x "$wt/gate/run-tests.sh" ]; then
		printf '%s\tfailed\t%s/gate/run-tests.sh missing — the canonical red check is not optional\n' "$id" "$wt"
		return 1
	fi
	if (cd "$wt" && ./gate/run-tests.sh -q >>"$log" 2>&1); then
		printf '%s\tfailed\tthe suite is GREEN at %s — vacuous lane, or it tests something that already exists\n' \
			"$id" "${base:0:12}"
		return 1
	fi

	printf '%s\tok\tred at %s\n' "$id" "${base:0:12}"
}

sysdv_cmd() {
	local ledger="" level="" base="" width=3 root="" child="" dry=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--ledger) ledger="${2:-}"; shift 2 ;;
		--level) level="${2:-}"; shift 2 ;;
		--base) base="${2:-}"; shift 2 ;;
		--width) width="${2:-}"; shift 2 ;;
		--root) root="${2:-}"; shift 2 ;;
		--child) child="${2:-}"; shift 2 ;;
		--dry-run) dry=1; shift ;;
		*) die "unknown argument '$1'" ;;
		esac
	done
	[ -n "$ledger" ] && [ -f "$ledger" ] || die "--ledger <file> required"
	[ -n "$level" ] || die "--level L3 (or L2/L1/L0) required"
	[ -n "$base" ] || die "--base <pre-implementation commit> required"
	git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || die "'$base' is not a commit here"
	base="$(git rev-parse "${base}^{commit}")"
	case "$width" in '' | *[!0-9]*) die "--width must be a positive integer" ;; esac
	[ "$width" -ge 1 ] || die "--width must be a positive integer"
	if [ -z "$child" ]; then
		[ -f "$AGENT_FILE" ] || die "agent file not found: $AGENT_FILE (set PI_SYSDV_AGENT)"
		awk 'BEGIN{n=0} /^---$/{n++; next} n>=2 && NF' "$AGENT_FILE" | grep -q . ||
			die "agent file has no body: $AGENT_FILE"
	fi

	[ -n "$root" ] || root="$(mktemp -d "${TMPDIR:-/tmp}/vmodel-wave-XXXXXX")"
	mkdir -p "$root"

	local -a ids=()
	local id lvl _tests
	while IFS=$'\t' read -r id lvl _tests; do
		[ -n "$id" ] || continue
		[ "$lvl" = "$level" ] || continue
		ids+=("$id")
	done < <(rows_cmd "$ledger")

	[ "${#ids[@]}" -gt 0 ] || die "no rows at level $level in $ledger"
	printf 'wave: level %s, base %s, %s row(s), width %s\n' "$level" "${base:0:12}" "${#ids[@]}" "$width"
	printf 'wave: worktrees under %s\n' "$root"

	if [ "$dry" = 1 ]; then
		printf '  would run: %s\n' "${ids[@]}"
		return 0
	fi

	local running=0
	for id in "${ids[@]}"; do
		while [ "$running" -ge "$width" ]; do
			wait -n || true
			running=$((running - 1))
		done
		(run_lane "$id" "$ledger" "$base" "$root" "$child" >"$root/$id.result" 2>&1) &
		running=$((running + 1))
	done
	wait || true

	local fails=0 ok=0
	for id in "${ids[@]}"; do
		if [ -s "$root/$id.result" ]; then
			cat "$root/$id.result"
			if grep -q "	ok	" "$root/$id.result"; then ok=$((ok + 1)); else fails=$((fails + 1)); fi
		else
			printf '%s\tfailed\tno result (subshell died)\n' "$id"
			fails=$((fails + 1))
		fi
	done

	printf 'wave: %s/%s lanes ok, %s failed\n' "$ok" "${#ids[@]}" "$fails"
	[ "$fails" -eq 0 ]
}

cmd="${1:-}"
shift || true
case "$cmd" in
rows) rows_cmd "$@" ;;
levels) levels_cmd "$@" ;;
sysdv) sysdv_cmd "$@" ;;
*) usage; exit 2 ;;
esac
