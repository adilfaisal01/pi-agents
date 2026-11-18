#!/usr/bin/env bash
# selftest.sh — self-test for review-lanes, in a throwaway repo.
#
# The subject is the failure that is invisible everywhere else: a lane that resolves its
# package to the MAIN tree because a shared venv, an editable install or a console script
# pointed there. That round is green, the record is green, and the finding it should have
# raised was never possible. "verify REFUSES a foreign pythonpath" is the point; the rest
# of the cases are the layout that makes a same-depth worktree worth the trouble.
#
# No network, no model. --install is exercised only when LANES_TEST_INSTALL=1.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/../bin/review-lanes"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
check() { # check <name> <expected-rc> <actual-rc>
	if [ "$3" -eq "$2" ]; then
		printf '  ok    %s\n' "$1"
		pass=$((pass + 1))
	else
		printf '  FAIL  %s (expected rc=%s, got rc=%s)\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}
same() { # same <name> <expected> <actual>
	if [ "$2" = "$3" ]; then
		printf '  ok    %s\n' "$1"
		pass=$((pass + 1))
	else
		printf '  FAIL  %s (expected %s, got %s)\n' "$1" "$2" "$3"
		fail=$((fail + 1))
	fi
}

echo "review-lanes selftest"

# --- independence ------------------------------------------------------------------
# Borrowed vocabulary, nothing load-bearing: the tool may call a commit a pin and a
# checkout a lane, but it must not name, import, or shell out to another project. The
# tokens below are a deny-list — their job is to be absent from the subject — so naming
# them here is the guard, not a reference.
foreign="$(grep -nE 'v-model|gate/|wave\.sh|sysdv|ledger\.md|shinro-' "$SUBJECT" || true)"
if [ -z "$foreign" ]; then
	check "names no other project" 0 0
else
	printf '%s\n' "$foreign"
	check "names no other project" 0 1
fi

# --- a repo shaped like the real ones: a sibling path dep, a src/ layout -------------
mkdir -p "$TMP/work/deps/mylib"
printf 'VALUE = 1\n' >"$TMP/work/deps/mylib/__init__.py"

MAIN="$TMP/work/main"
mkdir -p "$MAIN/src/mypkg" "$MAIN/tests"
printf 'VALUE = 2\n' >"$MAIN/src/mypkg/__init__.py"
printf 'def test_placeholder():\n    assert True\n' >"$MAIN/tests/test_a.py"
cat >"$MAIN/pyproject.toml" <<'EOF'
[build-system]
requires = ["setuptools>=77"]
build-backend = "setuptools.build_meta"

[project]
name = "mypkg"
version = "0.0.0"

[tool.setuptools.packages.find]
where = ["src"]

[tool.uv.sources]
mylib = { path = "../deps/mylib" }
EOF
cat >"$MAIN/Cargo.toml" <<'EOF'
[package]
name = "mypkg"
version = "0.0.0"

[dependencies]
mylib = { path = "../deps/mylib" }
EOF

git -C "$MAIN" init -q .
git -C "$MAIN" config user.email test@invalid
git -C "$MAIN" config user.name test
git -C "$MAIN" add -A
git -C "$MAIN" commit -qm "initial"
A="$(git -C "$MAIN" rev-parse HEAD)"

# --- provision ----------------------------------------------------------------------
set +e
out="$("$SUBJECT" provision "$MAIN" 2>"$TMP/provision.err")"
rc=$?
set -e
check "provision creates a worktree" 0 "$rc"
WT="$(printf '%s\n' "$out" | sed -n 's/^WORKTREE=//p')"
same "worktree is a same-depth sibling" "$TMP/work/main.review.wt" "$WT"
same "worktree detached at HEAD" "$A" "$(git -C "$WT" rev-parse HEAD)"
same "pythonpath is the src tree" "$WT/src" "$(printf '%s\n' "$out" | sed -n 's/^PYTHONPATH=//p')"

if [ -d "$WT/../deps/mylib" ]; then
	check "a ../ path dep resolves from the worktree" 0 0
else
	check "a ../ path dep resolves from the worktree" 0 1
fi

# --- the assertion ------------------------------------------------------------------
set +e
"$SUBJECT" verify "$WT" >/dev/null 2>&1
rc=$?
set -e
check "verify accepts its own worktree" 0 "$rc"

set +e
"$SUBJECT" verify "$WT" --pythonpath "$MAIN/src" >/dev/null 2>&1
rc=$?
set -e
check "verify REFUSES a foreign pythonpath" 1 "$rc"

set +e
msg="$("$SUBJECT" verify "$WT" --pythonpath "$MAIN/src" 2>&1 >/dev/null)"
rc=$?
set -e
case "$msg" in
*REFUSED*OUTSIDE*) check "the refusal names the wrong tree" 0 0 ;;
*) check "the refusal names the wrong tree" 0 1 ;;
esac

# --- provision once, detach many ----------------------------------------------------
before="$(git -C "$MAIN" worktree list --porcelain | grep -c '^worktree ')"
set +e
"$SUBJECT" provision "$MAIN" >/dev/null 2>&1
rc=$?
set -e
check "re-provision at the same commit succeeds" 0 "$rc"
same "re-provision adds no worktree" "$before" "$(git -C "$MAIN" worktree list --porcelain | grep -c '^worktree ')"

printf '# second\n' >"$MAIN/src/mypkg/extra.py"
git -C "$MAIN" add -A
git -C "$MAIN" commit -qm "second"
B="$(git -C "$MAIN" rev-parse HEAD)"
set +e
"$SUBJECT" provision "$MAIN" --base "$B" >/dev/null 2>&1
rc=$?
set -e
check "re-provision detaches at a new commit" 0 "$rc"
same "the worktree moved to the new sha" "$B" "$(git -C "$WT" rev-parse HEAD)"
set +e
"$SUBJECT" verify "$WT" >/dev/null 2>&1
rc=$?
set -e
check "the environment survives the detach" 0 "$rc"

# --- refusals -----------------------------------------------------------------------
cat >"$MAIN/pyproject.toml" <<'EOF'
[project]
name = "mypkg"
version = "0.0.0"

[tool.uv.sources]
mylib = { path = "../nowhere" }
EOF
git -C "$MAIN" add -A
git -C "$MAIN" commit -qm "break the path dep"
set +e
"$SUBJECT" provision "$MAIN" --name bad >/dev/null 2>&1
rc=$?
set -e
check "a missing relative path dep is refused" 1 "$rc"
"$SUBJECT" remove "$TMP/work/main.bad.wt" --force >/dev/null 2>&1 || true
git -C "$MAIN" reset -q --hard "$B"

printf 'scratch\n' >"$WT/junk.txt"
set +e
"$SUBJECT" provision "$MAIN" --base "$B" >/dev/null 2>&1
rc=$?
set -e
check "a dirty worktree is refused" 1 "$rc"
rm -f "$WT/junk.txt"

mkdir -p "$TMP/notrepo"
set +e
"$SUBJECT" provision "$TMP/notrepo" >/dev/null 2>&1
rc=$?
set -e
check "a non-repo is a usage error" 2 "$rc"

set +e
"$SUBJECT" provision "$MAIN" --base deadbeef >/dev/null 2>&1
rc=$?
set -e
check "a bogus base is a usage error" 2 "$rc"

set +e
"$SUBJECT" provision "$WT" >/dev/null 2>&1
rc=$?
set -e
check "provisioning from inside a worktree is refused" 2 "$rc"

set +e
"$SUBJECT" >/dev/null 2>&1
rc=$?
set -e
check "no command is a usage error" 2 "$rc"

set +e
"$SUBJECT" provision >/dev/null 2>&1
rc=$?
set -e
check "provision with no repo is a usage error" 2 "$rc"

# --- remove -------------------------------------------------------------------------
set +e
"$SUBJECT" remove "$WT" >/dev/null 2>&1
rc=$?
set -e
check "remove drops the worktree" 0 "$rc"
if [ -e "$WT" ]; then check "the worktree is gone" 0 1; else check "the worktree is gone" 0 0; fi

# --- optional: the editable-install path (needs uv + a warm cache, no network) ------
if [ "${LANES_TEST_INSTALL:-0}" = 1 ]; then
	set +e
	"$SUBJECT" provision "$MAIN" --name inst --install >/dev/null 2>"$TMP/inst.err"
	rc=$?
	set -e
	check "--install provisions a venv" 0 "$rc"
	INST="$TMP/work/main.inst.wt"
	if [ -x "$TMP/work/main.inst.venv/bin/python" ]; then
		set +e
		cd / && PYTHONPATH= "$TMP/work/main.inst.venv/bin/python" -c \
			'import mypkg, sys
print(mypkg.__file__)
sys.exit(0 if mypkg.__file__.startswith(sys.argv[1]) else 1)' "$INST" >/dev/null 2>&1
		rc=$?
		set -e
		check "--install resolves inside the worktree" 0 "$rc"
	else
		check "--install resolves inside the worktree" 0 1
	fi
	"$SUBJECT" remove "$INST" --force >/dev/null 2>&1 || true
else
	printf '  skip  --install (set LANES_TEST_INSTALL=1; needs uv and a warm cache)\n'
fi

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
