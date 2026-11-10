#!/usr/bin/env bash
# wave.sh — the V-model's two waves, and the barrier between them.
#
#   ./gate/wave.sh rows <ledger>                    # id, level, tests
#   ./gate/wave.sh levels <ledger>                  # the levels present, bottom-up
#   ./gate/wave.sh sysdv  --ledger <f> --level L3 --base <sha> --confirm [...]
#   ./gate/wave.sh freeze --ledger <f> --level L3 --base <sha> --root <dir> [...]
#   ./gate/wave.sh build  --ledger <f> --level L3 --pin <sha> --confirm [...]
#   ./gate/wave.sh records <records.jsonl> [id]     # latest record per row
#
# `wave.sh` with no command prints the full usage.
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

PKG_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# The agent file belongs to THE PACKAGE, not to the repo being worked on: gate/ is
# meant to be dropped into a target repo, and that repo has no pi/agents/.
AGENT_FILE="${PI_SYSDV_AGENT:-$PKG_ROOT/pi/agents/sysdv.md}"
BUILD_AGENT_FILE="${PI_BUILD_AGENT:-$PKG_ROOT/pi/agents/build.md}"

usage() {
	cat >&2 <<'EOF'
usage: wave.sh <command> [options]

  rows <ledger>                     id, level, tests — one tab-separated line per row
  levels <ledger>                   the levels present, bottom-up (L3 before L0)

  sysdv  --ledger <f> --level L3 --base <sha> --confirm
         [--width 3] [--root <dir>] [--child <cmd>] [--dry-run]
         [--records <f>|--no-records]
         Wave 1: one test-author lane per row, at the pre-implementation commit.

  freeze --ledger <f> --level L3 --base <sha> --root <dir>
         [--records <f>|--no-records] [--message <msg>] [--dry-run]
         The barrier: compose the lanes' tests, require the whole suite RED at
         <base>, then commit the frozen surface. Prints the pin sha as its last
         line.

  build  --ledger <f> --level L3 --pin <sha> --confirm
         [--width 3] [--root <dir>] [--child <cmd>] [--dry-run]
         [--records <f>|--no-records]
         Wave 2: one implementation lane per row, at the pin, then the composed
         gate — serially, once.

  records <records.jsonl> [id]      latest record per row (append-only trail)

sysdv and build refuse to spawn lanes without --confirm: the human confirms the
ledger (plan authors it), then the wave runs. Exit 0 ok · 1 refused · 2 usage.
EOF
}
die() { printf 'wave: %s\n' "$*" >&2; exit 2; }
# A refusal is a wall, not a warning: nonzero exit, and the reason names the rule.
refuse() { printf 'wave: REFUSED — %s\n' "$*" >&2; exit 1; }
# Spawning lanes is the irreversible act of the apparatus, so it needs the human to
# have read the rows. `plan` authors the ledger; --confirm is the acknowledgment.
confirm_required() { # confirm_required <stage> <level> <count>
	cat >&2 <<EOF
wave: $1 would spawn $3 lane(s) at level $2.
wave: REFUSED — requirements are confirmed by the human before any lane spawns.
wave: Read the ledger rows, then add --confirm. (--dry-run shows the wave without it.)
EOF
	exit 2
}

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

# A ledger cell may say `none` or an em dash instead of being blank; both mean "nothing
# here". Treating a dash as a test name or a source path is how a `declared` row becomes
# a lane that can never be green.
blank_cell() { # blank_cell <value> -> the value, or nothing for none/-/em dash
	case "$1" in
	'' | - | — | none | None | NONE) return 0 ;;
	*) printf '%s' "$1" ;;
	esac
}

rows_cmd() {
	local ledger="${1:-}"
	[ -n "$ledger" ] && [ -f "$ledger" ] || die "usage: wave.sh rows <ledger>"
	awk -F'|' "$AWK_HELPERS"'
		/^\|[ ]*id[ ]*\|/ && !hdr { header(); next }
		hdr && !/^\|/ { exit }
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
		hdr && !/^\|/ { exit }
		hdr && /^\|[ ]*-+/ { next }
		hdr && /^\|/ && cell("id") == want { print cell(column); exit }
	' "$1"
}

levels_cmd() { # distinct levels present, bottom-up (L3 before L0)
	local ledger="${1:-}"
	[ -n "$ledger" ] && [ -f "$ledger" ] || die "usage: wave.sh levels <ledger>"
	rows_cmd "$ledger" | cut -f2 | grep -v '^$' | sort -r | uniq
}

# laneable_rows <ledger> <level> -> id<TAB>level<TAB>tests
# A row with no `tests` cell is structural or declared (docs/06): there is nothing to be
# red, so it is not a lane and no wave may manufacture one. Waves skip it and say so —
# silently dropping it would make the ledger's own "declared" rows look implemented.
laneable_rows() {
	rows_cmd "$1" | while IFS=$'\t' read -r id lvl tests; do
		[ "$lvl" = "$2" ] || continue
		tests="$(blank_cell "$tests")"
		if [ -z "$tests" ]; then
			printf 'wave: %s has no tests (structural/declared) — not a lane\n' "$id" >&2
			continue
		fi
		printf '%s\t%s\t%s\n' "$id" "$lvl" "$tests"
	done
}

# --- lock surface (docs/04) ------------------------------------------------
# The locked paths, and why each one is here: tests/** are the assertions,
# conftest.py can redefine fixtures, the pytest configuration IS the selector
# (addopts deselects a category without touching an assertion), and
# gate/run-tests.sh is the command itself. The pin is the sha of the commit that
# contains all of them, so this list only decides what a freeze STAGES and what a
# build lane may not touch — never what counts as frozen.
LOCK_PATHS=(tests conftest.py pyproject.toml pytest.ini tox.ini setup.cfg gate/run-tests.sh)

is_lock_path() {
	case "$1" in
	tests | test | __tests__ | spec) return 0 ;;
	tests/* | test/* | __tests__/* | spec/*) return 0 ;;
	conftest.py | */conftest.py) return 0 ;;
	pyproject.toml | pytest.ini | tox.ini | setup.cfg) return 0 ;;
	gate/run-tests.sh) return 0 ;;
	*) return 1 ;;
	esac
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

# --- records: an append-only audit trail -----------------------------------
# One JSON object per line, appended, never rewritten. A crashed wave keeps the lines
# it wrote; a reader never sees a half-line; a malformed line is skipped and counted
# rather than making the history unreadable. The latest line per row id is its current
# state, and every earlier line is the trail: the recorded red, the pin it was frozen
# at, the gate that finally went green.
#
# A record does NOT carry the verdict. proved / conditional / structural / declared is
# a judgement in the ledger (docs/06); the trail is what the verdict cites, and the
# fact that a lane was refused stays in the file instead of scrolling out of a log.
records_default() { # records_default <ledger> -> <ledger dir>/records.jsonl
	printf '%s/records.jsonl' "$(cd "$(dirname "$1")" && pwd)"
}

json_escape() {
	# backslash, quote, tab, CR, and embedded newlines (as \n), in that order.
	printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/\t/\\t/g' |
		tr -d '\r' | awk 'BEGIN{ORS=""} NR>1{printf "\\n"} {print}'
}

json_array() { # json_array <item>... -> ["a","b"]
	local out="" sep="" item
	for item in "$@"; do
		out="$out$sep\"$(json_escape "$item")\""
		sep=","
	done
	printf '[%s]' "$out"
}

# rec_append <file> <stage> <status> <id> <ledger> <test-place> <files-json> <extra-json>
# <extra-json> is a raw fragment like \"pin\":\"abc\", so each stage adds only the fields
# it actually knows (freeze knows the pin, a build lane does not).
rec_append() {
	local file="$1" stage="$2" status="$3" id="$4" ledger="$5"
	local test_place files="$7" extra="${8:-}"
	test_place="$(blank_cell "$6")"
	[ -n "$file" ] || return 0
	[ -n "$id" ] || return 0
	mkdir -p "$(dirname "$file")"
	# Append-only, including the newline case: a missing trailing newline is repaired
	# by ADDING one byte, never by rewriting a line.
	if [ -s "$file" ] && [ -n "$(tail -c 1 "$file")" ]; then printf '\n' >>"$file"; fi
	printf '{"record":"req","id":"%s","requirement":"%s","test_place":"%s","files_which_cover":%s,"status":"%s","stage":"%s","level":"%s","evidence":"%s","created_at":"%s"%s}\n' \
		"$(json_escape "$id")" \
		"$(json_escape "$(row_field "$ledger" "$id" requirement)")" \
		"$(json_escape "$test_place")" \
		"$files" \
		"$(json_escape "$status")" \
		"$(json_escape "$stage")" \
		"$(json_escape "$(row_field "$ledger" "$id" level)")" \
		"$(json_escape "$(row_field "$ledger" "$id" evidence)")" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		"$extra" >>"$file"
}

# The latest record matching an id, optionally filtered by status — used by a build
# lane to start from its own recorded red instead of from someone's summary of it.
latest_record_line() { # latest_record_line <file> <id> <status>
	local file="$1" id="$2" status="$3"
	[ -n "$file" ] && [ -f "$file" ] || return 0
	python3 - "$file" "$id" "$status" <<'PY'
import json, sys
path, rid, status = sys.argv[1], sys.argv[2], sys.argv[3]
found = None
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(rec, dict) and str(rec.get("id")) == rid and rec.get("status") == status:
            found = rec
if found:
    print(json.dumps(found))
PY
}

records_cmd() {
	local file="${1:-}" want="${2:-}"
	[ -n "$file" ] && [ -f "$file" ] || die "usage: wave.sh records <records.jsonl> [id]"
	python3 - "$file" "$want" <<'PY'
import json, sys
path, want = sys.argv[1], sys.argv[2]
latest, order, bad = {}, [], 0
with open(path, encoding="utf-8", errors="replace") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except json.JSONDecodeError:
            bad += 1
            continue
        if not isinstance(rec, dict) or not rec.get("id"):
            bad += 1
            continue
        rid = str(rec["id"])
        if rid not in latest:
            order.append(rid)
        latest[rid] = rec
ids = [want] if want else order
if not ids:
    print("records: no records", file=sys.stderr)
w = max([len(i) for i in ids] + [2])
for rid in ids:
    rec = latest.get(rid)
    if rec is None:
        print(f"records: no record for {rid}", file=sys.stderr)
        continue
    files = rec.get("files_which_cover") or []
    if isinstance(files, list):
        files = ",".join(str(p) for p in files)
    pin = rec.get("pin")
    pincol = ("@" + str(pin)[:12]) if pin else "-"
    print(f"{rid.ljust(w)}  {str(rec.get('status','?')):12}  {str(rec.get('stage','-')):8}  "
          f"{pincol:<14}{rec.get('test_place','-')}  {files}")
if bad:
    print(f"records: skipped {bad} malformed line(s)", file=sys.stderr)
PY
}

# worktree_add <worktree> <commit> <logfile>
# A wave root is a temp directory, and deleting it between runs leaves the worktree
# registered but missing; `git worktree add` then fails with "missing but already
# registered". Pruning clears only registrations whose directory is gone, so it is
# always safe to run first — and the retry covers a stale directory that still exists.
worktree_add() {
	local wt="$1" c="$2" log="$3"
	git worktree prune 2>/dev/null || true
	if git worktree add -q --detach "$wt" "$c" 2>>"$log"; then return 0; fi
	git worktree remove --force "$wt" 2>/dev/null || true
	git worktree prune 2>/dev/null || true
	git worktree add -q --detach "$wt" "$c" 2>>"$log"
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

	worktree_add "$wt" "$base" "$log" || {
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

# new_tests_not_red <runner-log> <new-test-paths-file>
# Prints the composed test files that contain a test which did NOT fail at the base
# commit — PASSED, SKIPPED or XPASS. Empty when every test in those files failed.
#
# This is the mechanical half of docs/04's "every new test must fail, for its stated
# reason": the suite-level red check cannot see one vacuously-passing test inside a
# lane whose neighbours are red, and that test would be frozen as if it measured
# something. Coverage caveat: it reads the runner's per-test output, so a runner that
# reports no per-test results leaves only the suite-level check — the caller says so
# rather than claiming a clean vacuity check.
new_tests_not_red() {
	awk -v list="$2" '
		BEGIN { while ((getline l < list) > 0) if (l != "") want[l] = 1 }
		index($0, "::") > 0 && $0 ~ / (PASSED|SKIPPED|XPASS)( |$)/ {
			for (w in want) if (index($0, w "::") == 1) seen[w] = 1
		}
		END { for (w in seen) print w }
	' "$1"
}

# --- composing lanes -------------------------------------------------------
# Compose is a mechanical apply of each lane's scoped diff onto a tree at the same
# commit — not a merge. Two lanes claiming one path is a partition failure (docs/02
# rule 1): the merge would become a human decision in the middle of an automated wave,
# so it is refused before anything is applied and no lane is cherry-picked around.

paths_json() { # paths_json <file> -> ["path",...]
	local -a out=()
	local p
	while IFS= read -r p; do [ -n "$p" ] && out+=("$p"); done <"$1"
	json_array ${out[@]+"${out[@]}"}
}

# lane_prepare <root> <id> <worktree> <commit>
# Reads the lane's already-filtered path list from <root>/<id>.paths and writes the
# patch the barrier applies. Returns 1 when the lane produced nothing on the surface
# it was allowed to touch.
lane_prepare() {
	local root="$1" id="$2" wt="$3" base="$4"
	local paths_file="$root/$id.paths" patch_file="$root/$id.patch"
	local -a paths=()
	local p
	while IFS= read -r p; do [ -n "$p" ] && paths+=("$p"); done <"$paths_file"
	[ "${#paths[@]}" -gt 0 ] || return 1
	# Stage the lane so untracked files appear in the diff; the patch is still limited
	# to the paths the lane was allowed to have touched.
	git -C "$wt" add -A . >/dev/null 2>&1 || true
	git -C "$wt" diff --binary --cached "$base" -- "${paths[@]}" >"$patch_file"
	[ -s "$patch_file" ] || return 1
}

compose_apply() { # compose_apply <root> <compose-dir> <commit> <id>...
	local root="$1" compose="$2" base="$3"
	shift 3
	local -a ids=("$@")
	local id p dup map="$root/compose.map"
	: >"$map"
	for id in "${ids[@]}"; do
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			printf '%s\t%s\n' "$p" "$id" >>"$map"
		done <"$root/$id.paths"
	done

	dup="$(sort -u "$map" | cut -f1 | uniq -d)"
	if [ -n "$dup" ]; then
		printf 'wave: REFUSED — two lanes claim the same path (docs/02 rule 1):\n' >&2
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			printf '  %s  <-  %s\n' "$p" \
				"$(awk -F'\t' -v want="$p" '$1==want{printf "%s ", $2}' "$map")" >&2
		done <<<"$dup"
		printf 'wave: merge the rows into one lane, or serialize them. Nothing was applied.\n' >&2
		exit 1
	fi

	if [ ! -e "$compose/.git" ]; then
		worktree_add "$compose" "$base" "$root/compose.log" ||
			refuse "could not create the compose worktree at $compose"
	fi
	if [ -n "$(git -C "$compose" status --porcelain -uall 2>/dev/null)" ]; then
		refuse "the compose worktree at $compose is not clean — use a fresh --root for a new barrier"
	fi

	for id in "${ids[@]}"; do
		(cd "$compose" && git apply --binary --whitespace=nowarn "$root/$id.patch") ||
			refuse "lane $id's patch did not apply onto ${base:0:12} (see $root/$id.patch)"
	done

	# The composed tree must be exactly the union of the lanes' scoped paths. Anything
	# else means a patch did something nobody declared, and the pin would freeze it.
	local expected actual
	expected="$(cut -f1 "$map" | sort -u)"
	actual="$(git -C "$compose" status --porcelain -uall | sed 's/^...//' | sed 's/.* -> //' | tr -d '"' |
		while IFS= read -r p; do
			[ -n "$p" ] || continue
			case "$p" in .*) continue ;; esac
			printf '%s\n' "$p"
		done | sort -u)"
	if [ "$expected" != "$actual" ]; then
		printf "wave: REFUSED — the composed tree is not the union of the lanes' scoped paths:\n" >&2
		printf '  expected: %s\n' "$(printf '%s' "$expected" | paste -sd' ' -)" >&2
		printf '  actual:   %s\n' "$(printf '%s' "$actual" | paste -sd' ' -)" >&2
		exit 1
	fi
	printf '%s\n' "$expected" >"$root/compose.paths"
}

# --- the barrier: freeze ---------------------------------------------------
freeze_cmd() {
	local ledger="" level="" base="" root="" records="" no_records=0 message="" dry=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--ledger) ledger="${2:-}"; shift 2 ;;
		--level) level="${2:-}"; shift 2 ;;
		--base) base="${2:-}"; shift 2 ;;
		--root) root="${2:-}"; shift 2 ;;
		--records) records="${2:-}"; shift 2 ;;
		--no-records) no_records=1; shift ;;
		--message) message="${2:-}"; shift 2 ;;
		--dry-run) dry=1; shift ;;
		*) die "unknown argument '$1'" ;;
		esac
	done
	[ -n "$ledger" ] && [ -f "$ledger" ] || die "--ledger <file> required"
	[ -n "$level" ] || die "--level L3 (or L2/L1/L0) required"
	[ -n "$base" ] || die "--base <pre-implementation commit> required"
	git rev-parse --verify --quiet "${base}^{commit}" >/dev/null || die "'$base' is not a commit here"
	base="$(git rev-parse "${base}^{commit}")"
	[ -n "$root" ] || die "--root <dir> required — the root the sysdv wave wrote"
	[ -d "$root" ] || die "no such wave root: $root"

	local -a ids=()
	local id lvl
	while IFS=$'\t' read -r id lvl _; do
		[ -n "$id" ] || continue
		ids+=("$id")
	done < <(laneable_rows "$ledger" "$level")
	[ "${#ids[@]}" -gt 0 ] || die "no laneable rows at level $level in $ledger (a row with no tests is structural or declared)"

	# Freeze only a wave that finished. A lane that failed did not produce tests anyone
	# read, and freezing its neighbours would pin a suite with a hole in it.
	for id in "${ids[@]}"; do
		[ -s "$root/$id.result" ] ||
			refuse "lane $id has no result in $root — run 'wave.sh sysdv' first"
		grep -q "	ok	" "$root/$id.result" ||
			refuse "lane $id did not finish ok: $(head -1 "$root/$id.result")"
		[ -e "$root/$id/.git" ] || refuse "lane $id has no worktree at $root/$id"
		changed_paths "$root/$id" | while IFS= read -r p; do
			in_scope "$p" && printf '%s\n' "$p"
		done >"$root/$id.paths"
		lane_prepare "$root" "$id" "$root/$id" "$base" ||
			refuse "lane $id produced no diff on the frozen surface at ${base:0:12}"
	done

	if [ "$dry" = 1 ]; then
		printf 'wave: freeze would compose %s at %s\n' "${ids[*]}" "${base:0:12}"
		for id in "${ids[@]}"; do
			printf '  %s: %s\n' "$id" "$(paste -sd' ' - <"$root/$id.paths")"
		done
		return 0
	fi

	compose_apply "$root" "$root/compose" "$base" "${ids[@]}"

	# The barrier's two mechanical checks. The whole suite must be RED at <base> — the
	# pre-implementation commit is the only place that proves the tests measure something
	# that does not exist yet — and it must collect cleanly, because a collection error
	# is a test that cannot even be wrong.
	if (cd "$root/compose" && ./gate/run-tests.sh -v >"$root/compose-red.log" 2>&1); then
		refuse "the composed suite is GREEN at ${base:0:12} — every new test must be red there (docs/04); see $root/compose-red.log"
	fi
	# ... and red per test, not just per suite: a lane whose neighbours are red can still
	# ship a test that passes at the base commit, and that test would be frozen as if it
	# measured something (docs/03 rejects it, docs/04 requires every new test to fail).
	local vacuous
	vacuous="$(new_tests_not_red "$root/compose-red.log" "$root/compose.paths")"
	if [ -n "$vacuous" ]; then
		refuse "a new test does not fail at ${base:0:12} — vacuous or already true (docs/03): $(printf '%s' "$vacuous" | paste -sd, -)"
	fi
	if ! grep -qE ' (PASSED|FAILED|ERROR|SKIPPED|XPASS|XFAIL) ' "$root/compose-red.log"; then
		printf 'wave: note — the runner reported no per-test results; vacuity was checked only at suite level\n' >&2
	fi
	if ! (cd "$root/compose" && ./gate/run-tests.sh --collect-only -q >"$root/compose-collect.log" 2>&1); then
		refuse "the composed suite does not collect cleanly (see $root/compose-collect.log)"
	fi

	[ -n "$message" ] ||
		message="(test): freeze spec ${level} — tests for $(printf '%s' "${ids[*]}" | tr ' ' ','), red at ${base:0:12}"

	local -a staged=()
	local p
	for p in "${LOCK_PATHS[@]}"; do
		[ -e "$root/compose/$p" ] && staged+=("$p")
	done
	[ "${#staged[@]}" -gt 0 ] || refuse "none of the lock paths exist in the composed tree"
	if ! (cd "$root/compose" && git add -- "${staged[@]}"); then
		refuse "could not stage the frozen surface in $root/compose"
	fi
	if (cd "$root/compose" && git diff --cached --quiet); then
		refuse "nothing to freeze — the lanes changed nothing on the frozen surface"
	fi
	if ! (cd "$root/compose" && git commit -q -m "$message"); then
		refuse "could not create the freeze commit in $root/compose"
	fi
	local pin
	pin="$(git -C "$root/compose" rev-parse HEAD)"
	# The pin lives on a detached worktree under a temp directory. A ref is what keeps it
	# reachable: without one, cleaning $TMPDIR leaves the commit unreferenced and a later
	# `git gc` collects the frozen spec out of existence (the sha in the ledger would then
	# resolve to nothing). The ref also gives the human a name to land.
	git update-ref "refs/vmodel/pins/${level}-${pin:0:12}" "$pin"

	if [ -z "$records" ] && [ "$no_records" != 1 ]; then records="$(records_default "$ledger")"; fi
	for id in "${ids[@]}"; do
		rec_append "$records" freeze frozen "$id" "$ledger" \
			"$(row_field "$ledger" "$id" tests)" "$(paths_json "$root/$id.paths")" \
			",\"base\":\"$base\",\"pin\":\"$pin\""
	done

	printf 'wave: frozen %s at level %s\n' "$(printf '%s' "${ids[*]}" | tr ' ' ',')" "$level"
	printf 'wave: %s\n' "$message"
	printf 'wave: pin ref refs/vmodel/pins/%s-%s\n' "$level" "${pin:0:12}"
	printf '%s\n' "$pin"
}

sysdv_cmd() {
	local ledger="" level="" base="" width=3 root="" child="" dry=0
	local records="" no_records=0 confirm=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--ledger) ledger="${2:-}"; shift 2 ;;
		--level) level="${2:-}"; shift 2 ;;
		--base) base="${2:-}"; shift 2 ;;
		--width) width="${2:-}"; shift 2 ;;
		--root) root="${2:-}"; shift 2 ;;
		--child) child="${2:-}"; shift 2 ;;
		--records) records="${2:-}"; shift 2 ;;
		--no-records) no_records=1; shift ;;
		--dry-run) dry=1; shift ;;
		--confirm) confirm=1; shift ;;
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
		ids+=("$id")
	done < <(laneable_rows "$ledger" "$level")

	[ "${#ids[@]}" -gt 0 ] || die "no laneable rows at level $level in $ledger (a row with no tests is structural or declared)"
	printf 'wave: level %s, base %s, %s row(s), width %s\n' "$level" "${base:0:12}" "${#ids[@]}" "$width"
	printf 'wave: worktrees under %s\n' "$root"

	if [ "$dry" = 1 ]; then
		printf '  would run: %s\n' "${ids[@]}"
		return 0
	fi
	[ "$confirm" = 1 ] || confirm_required sysdv "$level" "${#ids[@]}"

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

	local fails=0 ok=0 id status detail files_json
	if [ -z "$records" ] && [ "$no_records" != 1 ]; then records="$(records_default "$ledger")"; fi
	for id in "${ids[@]}"; do
		status=""
		detail=""
		files_json="[]"
		if [ -s "$root/$id.result" ]; then
			cat "$root/$id.result"
			detail="$(head -1 "$root/$id.result" | cut -f3-)"
			if grep -q "	ok	" "$root/$id.result"; then
				ok=$((ok + 1))
				status="red_recorded"
				changed_paths "$root/$id" >"$root/$id.paths" 2>/dev/null || : >"$root/$id.paths"
				files_json="$(paths_json "$root/$id.paths")"
			else
				fails=$((fails + 1))
				status="refused"
			fi
		else
			printf '%s\tfailed\tno result (subshell died)\n' "$id"
			fails=$((fails + 1))
			status="failed"
			detail="no result (subshell died)"
		fi
		# A refusal is a record too: the trail says the lane ran and was sent back,
		# which is the difference between "not done" and "never asked".
		[ -z "$status" ] || rec_append "$records" sysdv "$status" "$id" "$ledger" \
			"$(row_field "$ledger" "$id" tests)" "$files_json" \
			",\"base\":\"$base\",\"pin\":null,\"detail\":\"$(json_escape "$detail")\""
	done

	printf 'wave: %s/%s lanes ok, %s failed\n' "$ok" "${#ids[@]}" "$fails"
	[ "$fails" -eq 0 ]
}

# --- wave 2: build lanes against the pin -----------------------------------
# A lane is one worktree and one write scope, and it holds one or more rows. The
# partition table in the ledger (docs/02) decides the grouping: rows whose interfaces are
# not disjoint are ONE lane, because no two worktrees can satisfy them independently — a
# parser cannot be green without the tokenizer it imports. A row the table does not name
# is its own lane.
#
# A lane also cannot be green on the whole suite: every lane starts at the pin, where
# every row's tests exist and the ones it does not own are still red. So the lane's own
# check selects the lane's tests (`-k`), and the composed gate — run once, with no
# selection — is the only whole-suite green. That distinction is the V: lanes are
# row-scoped, the delivery claim is not.

lane_groups() { # lane_groups <ledger> -> "lane<TAB>rows" from the partition table
	local ledger="$1"
	awk -F'|' "$AWK_HELPERS"'
		/^\|[ ]*lane[ ]*\|/ && !hdr { header(); next }
		hdr && !/^\|/ { exit }
		hdr && /^\|[ ]*-+/ { next }
		hdr && /^\|/ {
			if (cell("lane") != "" && cell("rows") != "") printf "%s\t%s\n", cell("lane"), cell("rows")
		}
	' "$ledger"
}

row_test_selection() { # row_test_selection <ledger> <id> -> -k expression, or empty
	local tests_raw
	tests_raw="$(blank_cell "$(row_field "$1" "$2" tests)")"
	[ -n "$tests_raw" ] || return 0
	local -a names=()
	local t name
	while IFS= read -r t; do
		[ -n "$t" ] || continue
		case "$t" in
		*::*) name="${t##*::}" ;;
		*) name="$(basename "$t")" ;;
		esac
		[ -n "$name" ] && names+=("$name")
	done < <(printf '%s\n' "$tests_raw" | tr ',' '\n' | tr -s '[:space:]' '\n' | sed '/^$/d')
	[ "${#names[@]}" -gt 0 ] || return 0
	local out="" sep="" n
	for n in "${names[@]}"; do
		out="$out$sep$n"
		sep=" or "
	done
	printf '%s' "$out"
}

row_sources() { # row_sources <ledger> <id> -> one path per line, no trailing slash
	local raw
	raw="$(blank_cell "$(row_field "$1" "$2" sources)")"
	[ -n "$raw" ] || return 0
	printf '%s\n' "$raw" | tr ',' '\n' | tr -s '[:space:]' '\n' | sed 's:/$::' | sed '/^$/d'
}

lane_ids() { # lane_ids <ids-csv> -> one id per line
	# The trailing newline is load-bearing: with no comma in the cell, `tr` emits no
	# newline and `read` returns nonzero at EOF without a delimiter, so the loop body
	# would never run and every lane would look empty.
	printf '%s\n' "$1" | tr ',' '\n' | tr -s '[:space:]' '\n' | sed '/^$/d'
}

# lane_fail <ids-csv> <status> <message>
# One result line per row: a lane's failure is each of its rows' failure, and the trail
# must say so rather than leaving the other rows looking untouched.
lane_fail() {
	local r
	while IFS= read -r r; do
		[ -n "$r" ] || continue
		printf '%s\t%s\t%s\n' "$r" "$2" "$3"
	done < <(lane_ids "$1")
}

run_build_lane() { # run_build_lane <lane> <ids-csv> <ledger> <pin> <root> <child> <records>
	local lane="$1" csv="$2" ledger="$3" pin="$4" root="$5" child="${6:-}" records="${7:-}"
	local wt="$root/$lane" log="$root/$lane.log"
	local -a rowids=()
	local r s x sel
	while IFS= read -r r; do [ -n "$r" ] && rowids+=("$r"); done < <(lane_ids "$csv")

	# The lane's write scope is the union of its rows' sources and its check is the union
	# of its rows' tests. Both are refusals, not warnings: a lane that does not know what
	# it may write has no wall at all (docs/05).
	local -a sources=()
	local all_sel="" sel_sep=""
	for r in "${rowids[@]}"; do
		local src_raw dup
		src_raw="$(row_sources "$ledger" "$r")"
		if [ -z "$src_raw" ]; then
			lane_fail "$csv" refused "no sources column — row $r names no write scope, so the lane has no wall (docs/05)"
			return 1
		fi
		while IFS= read -r s; do
			[ -n "$s" ] || continue
			if is_lock_path "$s"; then
				lane_fail "$csv" refused "sources include the frozen surface ($s) — a build lane never edits a locked test"
				return 1
			fi
			dup=0
			for x in ${sources[@]+"${sources[@]}"}; do
				[ "$x" = "$s" ] && dup=1
			done
			if [ "$dup" = 0 ]; then sources+=("$s"); fi
		done <<<"$src_raw"
		sel="$(row_test_selection "$ledger" "$r")"
		if [ -n "$sel" ]; then
			all_sel="$all_sel$sel_sep$sel"
			sel_sep=" or "
		fi
	done

	worktree_add "$wt" "$pin" "$log" || {
		lane_fail "$csv" refused "worktree add at ${pin:0:12} failed (see $log)"
		return 1
	}
	[ -e "$wt/.git" ] || {
		lane_fail "$csv" refused "worktree add reported success but $wt is not a worktree"
		return 1
	}

	{
		printf 'Lane: %s — %s row(s)\n\n' "$lane" "${#rowids[@]}"
		for r in "${rowids[@]}"; do
			printf 'Row: %s\n\nRequirement: %s\n\nDesign: %s\n\nInterface: %s\n\n' \
				"$r" \
				"$(row_field "$ledger" "$r" requirement)" \
				"$(row_field "$ledger" "$r" design)" \
				"$(row_field "$ledger" "$r" interface)"
			local t red
			t="$(row_field "$ledger" "$r" tests)"
			[ -n "$t" ] && printf 'Frozen tests (locked, must not be edited): %s\n\n' "$t"
			red="$(latest_record_line "$records" "$r" red_recorded)"
			[ -n "$red" ] && printf 'Recorded red run for %s:\n%s\n\n' "$r" "$red"
		done
		# The label is stable on purpose: it is the contract a lane reads, and the
		# stubs in gate/test-barrier.sh parse it.
		printf 'Write scope: %s\n' "${sources[*]}"
		if [ "${#rowids[@]}" -gt 1 ]; then
			printf 'This scope is the union of the lane rows above; one lane means one worktree\n'
			printf 'and one build agent, because these rows share an interface (docs/02 rule 2).\n'
		fi
		printf 'Locked surface you may not touch: tests/**, conftest.py, pyproject.toml, pytest.ini, tox.ini, setup.cfg, gate/run-tests.sh\n'
		printf 'Worktree: %s\nYou are at the PIN %s. The suite is red here, and that red is the row.\n\n' "$wt" "$pin"
		if [ -n "$all_sel" ]; then
			printf 'Your lane check (these rows only): ./gate/run-tests.sh -k "%s"\n' "$all_sel"
			printf 'Other rows are still red at this pin. That is expected; do not implement them.\n\n'
		else
			printf 'These rows name no tests: the composed gate is their only check.\n\n'
		fi
		printf 'When a frozen test is wrong, STOP and say which row, which assertion, and what\n'
		printf 'the spec should say (docs/05 rule 4). Implementing against a wrong test must\n'
		printf 'never look like success.\n'
	} >"$root/$lane.task"

	if [ -n "$child" ]; then
		"$child" "$wt" "$root/$lane.task" >>"$log" 2>&1 || true
	else
		local body
		body="$(awk 'BEGIN{n=0} /^---$/{n++; next} n>=2' "$BUILD_AGENT_FILE")"
		if [ -z "$body" ]; then
			lane_fail "$csv" refused "build agent file has no body: $BUILD_AGENT_FILE"
			return 1
		fi
		(cd "$wt" && pi --mode json -p --no-session -ne \
			--tools read,grep,find,ls,bash,write,edit \
			--append-system-prompt "$body" \
			"$(cat "$root/$lane.task")") >>"$log" 2>&1 || true
	fi

	# post-check 1: the frozen surface is byte-identical to the pin. This is the exit
	# path docs/05 requires, and it runs before anything is said about the diff.
	if [ ! -x "$wt/gate/lock-check.sh" ]; then
		lane_fail "$csv" refused "$wt/gate/lock-check.sh missing — the lock check is not optional"
		return 1
	fi
	if ! (cd "$wt" && ./gate/lock-check.sh "$pin" >"$root/$lane.lock.log" 2>&1); then
		lane_fail "$csv" refused "the frozen surface moved (see $root/$lane.lock.log)"
		return 1
	fi

	# post-check 2: every write stays inside the lane's sources
	local outside
	outside="$(changed_paths "$wt" | while IFS= read -r p; do
		local inside=1
		for s in "${sources[@]}"; do
			case "$p" in "$s" | "$s"/*) inside=0 ;; esac
		done
		[ "$inside" = 0 ] || printf '%s\n' "$p"
	done)"
	if [ -n "$outside" ]; then
		lane_fail "$csv" refused "wrote outside the lane sources: $(printf '%s' "$outside" | paste -sd, -) (see $log)"
		return 1
	fi
	if [ -z "$(changed_paths "$wt")" ]; then
		# A lane that stops on a wrong spec writes nothing on purpose. Its report is the
		# artifact, so the refusal points at it rather than implying the lane did nothing.
		lane_fail "$csv" refused "wrote nothing — see the lane report in $log (a lane that stops on a wrong spec is a finding, not a failure)"
		return 1
	fi

	# post-check 3: the lane's own tests are green in the lane (the composed gate, which
	# runs the whole suite with no selection, comes later).
	if [ -n "$all_sel" ]; then
		if ! (cd "$wt" && ./gate/run-tests.sh -q -k "$all_sel" >>"$log" 2>&1); then
			lane_fail "$csv" failed "the lane's tests are still red at the pin (see $log)"
			return 1
		fi
	fi

	while IFS= read -r r; do
		[ -n "$r" ] || continue
		printf '%s\tok\tgreen at pin %s\n' "$r" "${pin:0:12}"
	done < <(lane_ids "$csv")
}

build_cmd() {
	local ledger="" level="" pin="" width=3 root="" child="" dry=0
	local records="" no_records=0 confirm=0
	while [ $# -gt 0 ]; do
		case "$1" in
		--ledger) ledger="${2:-}"; shift 2 ;;
		--level) level="${2:-}"; shift 2 ;;
		--pin) pin="${2:-}"; shift 2 ;;
		--width) width="${2:-}"; shift 2 ;;
		--root) root="${2:-}"; shift 2 ;;
		--child) child="${2:-}"; shift 2 ;;
		--records) records="${2:-}"; shift 2 ;;
		--no-records) no_records=1; shift ;;
		--dry-run) dry=1; shift ;;
		--confirm) confirm=1; shift ;;
		*) die "unknown argument '$1'" ;;
		esac
	done
	[ -n "$ledger" ] && [ -f "$ledger" ] || die "--ledger <file> required"
	[ -n "$level" ] || die "--level L3 (or L2/L1/L0) required"
	[ -n "$pin" ] || die "--pin <freeze commit sha> required"
	git rev-parse --verify --quiet "${pin}^{commit}" >/dev/null || die "'$pin' is not a commit here"
	pin="$(git rev-parse "${pin}^{commit}")"
	case "$width" in '' | *[!0-9]*) die "--width must be a positive integer" ;; esac
	[ "$width" -ge 1 ] || die "--width must be a positive integer"
	if [ -z "$child" ]; then
		[ -f "$BUILD_AGENT_FILE" ] || die "build agent file not found: $BUILD_AGENT_FILE (set PI_BUILD_AGENT)"
		awk 'BEGIN{n=0} /^---$/{n++; next} n>=2 && NF' "$BUILD_AGENT_FILE" | grep -q . ||
			die "build agent file has no body: $BUILD_AGENT_FILE"
	fi
	if [ -z "$records" ] && [ "$no_records" != 1 ]; then records="$(records_default "$ledger")"; fi

	local -a ids=()
	local id lvl
	while IFS=$'\t' read -r id lvl _; do
		[ -n "$id" ] || continue
		ids+=("$id")
	done < <(laneable_rows "$ledger" "$level")
	[ "${#ids[@]}" -gt 0 ] || die "no laneable rows at level $level in $ledger (a row with no tests is structural or declared)"

	# Group the rows into lanes (docs/02 rule 2). A row named by the partition table
	# belongs to that lane; a row named by two lanes is a partition error.
	local -a lane_names=() lane_rows=()
	local gl gr kept r n covered
	while IFS=$'\t' read -r gl gr; do
		[ -n "$gl" ] || continue
		kept=""
		while IFS= read -r r; do
			[ -n "$r" ] || continue
			for n in "${ids[@]}"; do
				if [ "$n" = "$r" ]; then
					case ",$kept," in
					*",$r,"*) ;;
					*) kept="$kept${kept:+,}$r" ;;
					esac
				fi
			done
		done < <(lane_ids "$gr")
		[ -n "$kept" ] || continue
		lane_names+=("$gl")
		lane_rows+=("$kept")
	done < <(lane_groups "$ledger")
	for id in "${ids[@]}"; do
		covered=0
		for n in ${lane_rows[@]+"${lane_rows[@]}"}; do
			case ",$n," in *",$id,"*) covered=$((covered + 1)) ;; esac
		done
		[ "$covered" -le 1 ] ||
			die "row $id is listed in $covered lanes in the partition table — a row belongs to one lane"
		if [ "$covered" = 0 ]; then
			lane_names+=("$id")
			lane_rows+=("$id")
		fi
	done

	printf 'wave: build level %s, pin %s, %s row(s) in %s lane(s), width %s\n' \
		"$level" "${pin:0:12}" "${#ids[@]}" "${#lane_names[@]}" "$width"
	local i
	for i in "${!lane_names[@]}"; do
		printf '  %s: rows %s\n' "${lane_names[$i]}" "${lane_rows[$i]}"
	done
	if [ "$dry" = 1 ]; then return 0; fi
	[ "$confirm" = 1 ] || confirm_required build "$level" "${#ids[@]}"

	[ -n "$root" ] || root="$(mktemp -d "${TMPDIR:-/tmp}/vmodel-build-XXXXXX")"
	mkdir -p "$root"
	printf 'wave: worktrees under %s\n' "$root"

	local running=0
	for i in "${!lane_names[@]}"; do
		while [ "$running" -ge "$width" ]; do
			wait -n || true
			running=$((running - 1))
		done
		(run_build_lane "${lane_names[$i]}" "${lane_rows[$i]}" "$ledger" "$pin" \
			"$root" "$child" "$records" >"$root/${lane_names[$i]}.result" 2>&1) &
		running=$((running + 1))
	done
	wait || true

	local fails=0 ok=0 detail row_ok
	local -a green_lanes=()
	for i in "${!lane_names[@]}"; do
		local lane="${lane_names[$i]}" rows="${lane_rows[$i]}"
		if [ -s "$root/$lane.result" ]; then
			cat "$root/$lane.result"
		else
			printf '%s\tfailed\tno result (subshell died)\n' "$lane"
		fi
		row_ok=1
		while IFS= read -r r; do
			[ -n "$r" ] || continue
			detail="$(grep -E "^${r}[[:space:]]" "$root/$lane.result" 2>/dev/null | head -1 | cut -f3-)"
			[ -n "$detail" ] || detail="no result (subshell died)"
			if grep -qE "^${r}[[:space:]]+ok([[:space:]]|$)" "$root/$lane.result" 2>/dev/null; then
				ok=$((ok + 1))
				changed_paths "$root/$lane" >"$root/$lane.paths" 2>/dev/null || : >"$root/$lane.paths"
				rec_append "$records" build built_green "$r" "$ledger" \
					"$(row_field "$ledger" "$r" tests)" "$(paths_json "$root/$lane.paths")" \
					",\"base\":\"$pin\",\"pin\":\"$pin\",\"lane\":\"$lane\""
			else
				fails=$((fails + 1))
				row_ok=0
				rec_append "$records" build refused "$r" "$ledger" \
					"$(row_field "$ledger" "$r" tests)" "[]" \
					",\"base\":\"$pin\",\"pin\":\"$pin\",\"lane\":\"$lane\",\"detail\":\"$(json_escape "$detail")\""
			fi
		done < <(lane_ids "$rows")
		if [ "$row_ok" = 1 ]; then green_lanes+=("$lane"); fi
	done
	printf 'wave: %s/%s rows ok in %s/%s lane(s), %s row(s) failed\n' \
		"$ok" "${#ids[@]}" "${#green_lanes[@]}" "${#lane_names[@]}" "$fails"

	# The composed gate. Green per lane is the classic integration failure: each lane's
	# tests are consistent with that lane's assumptions, and the composed tree is the
	# first place the assumptions meet (docs/02). It runs once, serially, and it is the
	# only run that supports the delivery claim.
	if [ "${#green_lanes[@]}" -gt 0 ]; then
		if [ "$fails" -gt 0 ]; then
			printf 'wave: composed gate skipped — %s row(s) did not go green\n' "$fails" >&2
		else
			local compose="$root/compose"
			for i in "${!green_lanes[@]}"; do
				lane_prepare "$root" "${green_lanes[$i]}" "$root/${green_lanes[$i]}" "$pin" ||
					refuse "lane ${green_lanes[$i]} produced no patch at the pin"
			done
			compose_apply "$root" "$compose" "$pin" "${green_lanes[@]}"
			if ! (cd "$compose" && ./gate/lock-check.sh "$pin" >"$root/gate-lock.log" 2>&1); then
				refuse "the composed tree drifted from the pin (see $root/gate-lock.log)"
			fi
			if ! (cd "$compose" && ./gate/run-tests.sh -q >"$root/gate-composed.log" 2>&1); then
				refuse "the composed suite is red — green per lane is not green composed (see $root/gate-composed.log)"
			fi
			for i in "${!green_lanes[@]}"; do
				local glane="${green_lanes[$i]}"
				while IFS= read -r r; do
					[ -n "$r" ] || continue
					rec_append "$records" gate gate_green "$r" "$ledger" \
						"$(row_field "$ledger" "$r" tests)" "$(paths_json "$root/$glane.paths")" \
						",\"base\":\"$pin\",\"pin\":\"$pin\",\"lane\":\"$glane\""
				done < <(lane_ids "${lane_rows[$i]}")
			done
			printf 'wave: composed gate green at pin %s\n' "${pin:0:12}"
		fi
	fi

	[ "$fails" -eq 0 ]
}

cmd="${1:-}"
shift || true
case "$cmd" in
rows) rows_cmd "$@" ;;
levels) levels_cmd "$@" ;;
sysdv) sysdv_cmd "$@" ;;
freeze) freeze_cmd "$@" ;;
build) build_cmd "$@" ;;
records) records_cmd "$@" ;;
*) usage; exit 2 ;;
esac
