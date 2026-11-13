#!/usr/bin/env bash
# lane-prepare.sh — give each review lane its own checkout of the change under review.
#
#   ./scripts/lane-prepare.sh prepare [--repo <path>] [--sha <ref>]
#   ./scripts/lane-prepare.sh clean   [--repo <path>]
#
# WHY. The lanes are real `pi` children, but the dispatcher resolves them against the
# PARENT's cwd (`resolveAgent(ctx.cwd, ...)` with no `cwd`) and the child inherits the
# parent's whole environment. Two consequences follow, and both are invisible in the
# output:
#
#   1. Both lanes read one mutable tree at different moments. A disagreement between them
#      can mean the tree changed, not that the code is ambiguous — and the merge is
#      instructed to read disagreement as signal.
#   2. A repro written to /tmp resolves the package through the inherited venv, i.e.
#      against the tree that venv was installed from. `CONF: high` then means "somebody
#      executed something", not "against the commit under review".
#
# WHAT. The change is materialised as a COMMIT and each lane gets a same-depth worktree at
# it, through `review-lanes`, which also refuses unless `import <pkg>` resolves inside that
# worktree. One sha for both lanes: comparability becomes structural instead of a copied
# scope string.
#
# MATERIALISING. When the scope is the staged diff there is nothing to check out — the
# index is not a commit. `git write-tree` + `git commit-tree` produce a dangling commit
# that holds exactly the index; HEAD, the index, the branch and the stash list are
# untouched. When nothing is staged the commit is HEAD itself.
#
# stdout is KEY=value; stderr is prose. MODE=worktree|shared says which dispatch to run, and
# a shared tree is a weaker review — say so rather than presenting it as equal.
#
# NO DEPENDENCY ON A MODE GUARD. Isolation needs writes (`git worktree add`, and a dangling
# `commit-tree` for a staged diff), so a session whose shell is read-only cannot have it.
# That degrades the review (MODE=shared, DEGRADED=read-only) rather than failing it: the
# swarm must be usable in any session, including one with no mode apparatus at all. Only a
# dirty lane worktree is a refusal — that is evidence from a previous run, not a limitation.
# Exit 0 ok · 1 refused · 2 usage.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANE_NAMES=(correctness quality)

die() { printf 'lane-prepare: %s\n' "$*" >&2; exit 2; }
refuse() { printf 'lane-prepare: REFUSED — %s\n' "$*" >&2; exit 1; }
note() { printf '  note  %s\n' "$*" >&2; }
ok() { printf '  ok    %s\n' "$*" >&2; }

usage() {
	cat >&2 <<'EOF'
usage: lane-prepare.sh <command> [options]

  prepare [--repo <path>] [--sha <ref>]
         Materialise the scope as a commit and provision one worktree per lane at it.
         Prints MODE=, SHA=, PARENT=, REPO=, CWD_CORRECTNESS=, CWD_QUALITY= on stdout.
         MODE=shared means the lanes share one tree; DEGRADED= names why. Isolated lanes
         are an improvement, never a precondition: a read-only shell or a missing tool
         degrades the review instead of aborting it.

  clean [--repo <path>]
         Remove both lane worktrees. Refuses nothing — a leftover dirty worktree is
         exactly what has to be discarded.

exit 0 ok, 1 refused, 2 usage.
EOF
}

# review-lanes is a separate project. Find it without hardcoding a checkout path:
# explicit override, then PATH, then a sibling checkout.
find_lanes() {
	if [ -n "${REVIEW_LANES:-}" ]; then
		[ -x "$REVIEW_LANES" ] || return 1
		printf '%s\n' "$REVIEW_LANES"
		return 0
	fi
	if command -v review-lanes >/dev/null 2>&1; then
		command -v review-lanes
		return 0
	fi
	if [ -x "$HERE/../review-lanes/bin/review-lanes" ]; then
		printf '%s\n' "$HERE/../review-lanes/bin/review-lanes"
		return 0
	fi
	return 1
}

repo_root() { # <path> -> toplevel
	git -C "$1" rev-parse --show-toplevel 2>/dev/null || die "not inside a git work tree: $1"
}

# --- materialise ------------------------------------------------------------
# Two paths, one commit: the index when the scope is the staged diff, HEAD otherwise.
materialise() {
	local root="$1" ref="$2" sha parent tree
	if [ -n "$ref" ]; then
		sha="$(git -C "$root" rev-parse --verify --quiet "${ref}^{commit}")" ||
			die "'$ref' is not a commit in $root"
		parent="$(git -C "$root" rev-parse -q --verify "${sha}^" || true)"
	elif ! git -C "$root" diff --cached --quiet; then
		# Materialising the index writes (a dangling tree and commit). A read-only shell
		# cannot, and that must not abort the review — fall back to HEAD and say so; the
		# provisioning attempt below will then degrade in the same way.
		parent="$(git -C "$root" rev-parse HEAD)"
		if tree="$(git -C "$root" write-tree)" &&
			sha="$(git -C "$root" commit-tree "$tree" -p "$parent" -m 'review: staged index')"; then
			note "staged index materialised as ${sha:0:10} (dangling; HEAD and the index are untouched)"
		else
			sha="$parent"
			note "could not materialise the staged index — reviewing HEAD instead"
		fi
	else
		sha="$(git -C "$root" rev-parse HEAD)"
		parent="$(git -C "$root" rev-parse -q --verify "${sha}^" || true)"
	fi
	printf '%s %s\n' "$sha" "$parent"
}

prepare() {
	local repo="." ref=""
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
		--sha) ref="${2:?--sha needs a value}"; shift 2 ;;
		*) die "prepare: unknown option '$1'" ;;
		esac
	done
	[ -d "$repo" ] || die "prepare: no such directory: $repo"
	local root sha parent
	root="$(repo_root "$repo")"
	read -r sha parent <<<"$(materialise "$root" "$ref")"

	# A dirty lane worktree is evidence a previous run left behind. Refuse before touching
	# anything, so the message is ours rather than a tool's.
	local lane wt
	for lane in "${LANE_NAMES[@]}"; do
		wt="$(dirname "$root")/$(basename "$root").$lane.wt"
		if [ -d "$wt" ] && [ -n "$(git -C "$wt" status --porcelain 2>/dev/null)" ]; then
			refuse "worktree is dirty — a lane wrote into it: $wt (run: $(basename "$0") clean)"
		fi
	done

	local lanes
	if ! lanes="$(find_lanes)"; then
		note "review-lanes not found."
		note "  fix: export REVIEW_LANES=/path/to/review-lanes/bin/review-lanes,"
		note "       put it on PATH, or check out review-lanes beside this repo."
		note "falling back to a SHARED tree: lanes run in $root, repros go to /tmp,"
		note "and the two tables are no longer guaranteed to describe the same code."
		printf 'MODE=shared\nDEGRADED=no-review-lanes\n'
		printf 'SHA=%s\nPARENT=%s\nREPO=%s\n' "$sha" "$parent" "$root"
		return 0
	fi

	local out
	local -A cwd=()
	for lane in "${LANE_NAMES[@]}"; do
		# stdout is the KEY=value block; stderr passes through (that is where the
		# resolution assertion reports ok/FAIL per package).
		if ! out="$("$lanes" provision "$root" --name "$lane" --base "$sha")"; then
			# Provisioning writes; a read-only shell cannot. Degrade, do not abort.
			note "could not provision the $lane worktree at ${sha:0:10} (see above)"
			note "the lanes will share $root and use /tmp for repros — a weaker review"
			printf 'MODE=shared\nDEGRADED=read-only-or-provision-failed\n'
			printf 'SHA=%s\nPARENT=%s\nREPO=%s\n' "$sha" "$parent" "$root"
			return 0
		fi
		wt="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')"
		[ -n "$wt" ] || refuse "review-lanes printed no WORKTREE for $lane"
		cwd["$lane"]="$wt"
	done
	# The whole point: same commit, two trees.
	[ "$(git -C "${cwd[correctness]}" rev-parse HEAD)" = "$sha" ] ||
		refuse "the correctness worktree is not at ${sha:0:10}"
	[ "$(git -C "${cwd[quality]}" rev-parse HEAD)" = "$sha" ] ||
		refuse "the quality worktree is not at ${sha:0:10}"
	ok "two worktrees at ${sha:0:10} — the lanes cannot race each other"

	[ -n "$parent" ] || note "no parent commit — the review is the whole tree at ${sha:0:10}"
	printf 'MODE=worktree\n'
	printf 'SHA=%s\n' "$sha"
	printf 'PARENT=%s\n' "$parent"
	printf 'REPO=%s\n' "$root"
	printf 'CWD_CORRECTNESS=%s\n' "${cwd[correctness]}"
	printf 'CWD_QUALITY=%s\n' "${cwd[quality]}"
	printf 'CLEAN=%s\n' "$HERE/scripts/lane-prepare.sh clean"
}

clean() {
	local repo="."
	while [ "$#" -gt 0 ]; do
		case "$1" in
		--repo) repo="${2:?--repo needs a value}"; shift 2 ;;
		*) die "clean: unknown option '$1'" ;;
		esac
	done
	local root parent base lane wt removed=0
	root="$(repo_root "$repo")"
	parent="$(dirname "$root")"
	base="$(basename "$root")"
	for lane in "${LANE_NAMES[@]}"; do
		wt="$parent/$base.$lane.wt"
		if [ ! -e "$wt" ]; then
			continue
		fi
		# git, not review-lanes: a leftover worktree must be removable even when the
		# tool that made it is gone or broken.
		git -C "$root" worktree remove --force "$wt"
		ok "removed $wt"
		removed=$((removed + 1))
	done
	if [ "$removed" -eq 0 ]; then
		note "no lane worktree for $base"
	fi
	printf 'REMOVED=%d\n' "$removed"
}

cmd="${1:-}"
[ "$#" -gt 0 ] && shift
case "$cmd" in
prepare) prepare "$@" ;;
clean) clean "$@" ;;
*) usage; exit 2 ;;
esac
