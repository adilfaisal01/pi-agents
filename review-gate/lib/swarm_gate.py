#!/usr/bin/env python3
"""swarm-gate — a review gate over the code-review-swarm lanes.

    swarm-gate [--repo PATH] [--base REF] [--scope PATH...]
               [--lanes correctness,quality] [--max-rounds N]
               [--same-signature-limit N] [--timeout SEC]
               [--agents DIR] [--ledger FILE] [--json] [--dry-run]

Exit codes
    0  no SEV1/SEV2 in the change under review (SEV3/4 may still be listed)
    1  SEV1/SEV2 present — fix them and re-run
    2  usage error, or nothing to review
    3  loop guard: a SEV1/2 signature survived N consecutive rounds
    4  round budget exhausted with SEV1/2 still open
    5  a lane is unusable: dispatch failed, no table, or no COVERAGE line

WHY THE LANES ARE PARSED HERE AND NOT BY THE SKILL. The skill's merge step is model
judgment (dedupe on "same broken invariant ±3 lines", contradiction handling, quality
severities mapped onto the merged scale). A gate cannot be built on a model's opinion of
its own output. This script reads each lane's own output contract — one markdown table
`| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |` plus `COVERAGE:` / `NOT CHECKED:`
lines — and applies a mechanical policy to it. The merged human table the skill produces
is untouched and remains the thing to read interactively; this adds a verdict, not a
second merge.

CONSEQUENCE, stated rather than hidden: this gate never reports the merged LENS/CONF
columns. It reports lane rows, deduped only when two lanes cite the same path:line at the
same severity. The skill's semantic dedupe stays where it is.

WHY THE CHANGE-SET KEY IS HEAD. The fix loop happens before any commit: the agent edits
the working tree, the gate re-runs, HEAD does not move. Keying the round counter on the
diff instead would reset the budget on every fix, which is the one thing it must not do.
Committing ends the change set — which matches the rule that nothing is committed without
an explicit go.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

LANE_TOOLS = "read,grep,find,ls,bash"
SEV_RE = re.compile(r"^SEV([1-4])$")
ID_RE = re.compile(r"^[A-Za-z]{0,2}[0-9]+$")
LOC_RE = re.compile(r"^(?P<path>[^:]+):(?P<line>[0-9]+)(?:\s*\((?P<sym>.*)\))?$")

# Lane name -> the agents/<name>.md file that carries its lens, contract and model.
LANE_AGENT = {"correctness": "review-correctness", "quality": "review-quality"}


class GateError(Exception):
    """A condition the gate reports as an exit code rather than a traceback."""

    def __init__(self, code: int, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


# --- shell -------------------------------------------------------------------


def run(cmd: list[str], cwd: str | None = None, timeout: float | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
        check=False,
    )


def git(repo: str, *args: str) -> str:
    proc = run(["git", "-C", repo, *args])
    if proc.returncode != 0:
        raise GateError(2, f"git {' '.join(args)} failed: {proc.stderr.strip()}")
    return proc.stdout.strip()


# --- lane agents -------------------------------------------------------------


def frontmatter_field(text: str, key: str) -> str:
    """Value of `key:` in the YAML-ish frontmatter, or ''."""
    fence = 0
    for line in text.splitlines():
        if line.strip() == "---":
            fence += 1
            continue
        if fence == 1 and line.startswith(key + ":"):
            return line.split(":", 1)[1].strip()
    return ""


def agent_body(text: str) -> str:
    """Everything after the second `---`, i.e. the lane's lens and output contract."""
    parts = text.split("---", 2)
    return parts[2].lstrip("\n") if len(parts) == 3 else text


def load_agent(agents_dir: Path, lane: str) -> tuple[str, str]:
    path = agents_dir / f"{LANE_AGENT.get(lane, lane)}.md"
    if not path.exists():
        raise GateError(2, f"lane agent not found: {path}")
    text = path.read_text()
    model = frontmatter_field(text, "model")
    if not model:
        raise GateError(2, f"{path.name} pins no model — the gate will not pick one for it")
    return model, agent_body(text)


# --- dispatch ----------------------------------------------------------------


def lane_prompt(mode: str, sha: str, parent: str, base: str, scope: list[str]) -> str:
    if mode == "worktree":
        # The lane's checkout IS the change, so the diff is against its parent, not HEAD.
        what = (
            f"The change under review is materialised as commit {sha[:10]} in this checkout "
            f"(its parent is {parent[:10]}). Review `git diff {parent} {sha}` and the code it touches."
        )
    else:
        what = (
            f"Review the uncommitted change in this repository: `git diff {base}` "
            f"(working tree against {base[:10]}), and the code it touches."
        )
    where = ""
    if scope:
        where = "Restrict the review to these paths: " + ", ".join(scope) + "."
    return (
        f"{what}\n{where}\n"
        "Follow the output contract in your system prompt exactly: one markdown table with a "
        "`| ID | SEV | LOCATION | FINDING | TRIGGER | FIX |` header, SEV1-SEV4, every row "
        "carrying `path:line (symbol)`, then the `COVERAGE:` and `NOT CHECKED:` lines. "
        "Do not apply fixes."
    ).strip()


def dispatch_lane(
    lane: str,
    model: str,
    body: str,
    cwd: str,
    prompt: str,
    timeout: float,
    tmpdir: Path,
    transcripts: Path | None = None,
    transcript_name: str = "",
) -> dict:
    body_file = tmpdir / f"{lane}.body"
    body_file.write_text(body)
    cmd = [
        "pi",
        "-p",
        "--no-session",
        "-ne",
        "--model",
        model,
        "--tools",
        LANE_TOOLS,
        "--append-system-prompt",
        str(body_file),
        prompt,
    ]
    started = time.time()
    try:
        proc = run(cmd, cwd=cwd, timeout=timeout)
    except subprocess.TimeoutExpired as exc:
        result = {"lane": lane, "model": model, "ok": False, "reason": f"timed out after {timeout:g}s", "text": ""}
        save_transcript(transcripts, transcript_name, lane, result, b"" if exc.stdout is None else str(exc.stdout).encode())
        return result
    elapsed = time.time() - started
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout).strip().splitlines()[-3:]
        result = {
            "lane": lane,
            "model": model,
            "ok": False,
            "reason": f"pi exited {proc.returncode}: " + " / ".join(tail),
            "text": proc.stdout,
            "stderr": proc.stderr,
            "elapsed": elapsed,
        }
        save_transcript(transcripts, transcript_name, lane, result)
        return result
    result = {"lane": lane, "model": model, "ok": True, "text": proc.stdout, "stderr": proc.stderr, "elapsed": elapsed}
    save_transcript(transcripts, transcript_name, lane, result)
    return result


def save_transcript(dir_: Path | None, stem: str, lane: str, result: dict, extra: bytes = b"") -> None:
    """Keep what the lane actually said, including on failure.

    The parser keeps only table rows and the two trailing lines, so without this a lane
    that fails, or that explains itself in prose, leaves nothing to inspect. Written into
    the same per-date work folder as the ledger, which is gitignored.
    """
    if dir_ is None:
        return
    dir_.mkdir(parents=True, exist_ok=True)
    out = dir_ / f"{stem}-{lane}.md"
    out.write_text(result.get("text") or "")
    stream = result.get("stderr") or ""
    if extra:
        stream += extra.decode(errors="replace")
    if not result.get("ok") and stream:
        out.with_suffix(".err").write_text(stream)


# --- parsing -----------------------------------------------------------------


def split_row(line: str) -> list[str]:
    """Cells of a markdown table row, honouring escaped pipes."""
    stripped = line.strip()
    if stripped.startswith("|"):
        stripped = stripped[1:]
    if stripped.endswith("|"):
        stripped = stripped[:-1]
    cells = [c.strip() for c in re.split(r"(?<!\\)\|", stripped)]
    return [c.replace("\\|", "|") for c in cells]


def norm(text: str) -> str:
    return re.sub(r"[`*_]", "", text).replace("\\", "").strip()


def parse_lane(lane: str, text: str) -> dict:
    """Rows from one lane's transcript, plus whether its contract held.

    A lane that emitted no table, or no COVERAGE line, is UNUSABLE — never empty. The
    difference between "nothing found" and "the reviewer never reported" is the only
    thing a gate must not blur.
    """
    rows: list[dict] = []
    header = False
    coverage: str | None = None
    not_checked: str | None = None

    for line in text.splitlines():
        low = line.strip()
        if low.lower().startswith("coverage:"):
            coverage = low.split(":", 1)[1].strip()
            continue
        if low.lower().startswith("not checked:"):
            not_checked = low.split(":", 1)[1].strip()
            continue
        if not low.startswith("|"):
            continue
        cells = split_row(low)
        if len(cells) < 2:
            continue
        if cells[0].lower() == "id" and cells[1].lower() == "sev":
            header = True
            continue
        if all(set(c) <= set("-: ") for c in cells if c):
            continue  # |----|-----|
        ident, sev_cell = norm(cells[0]), norm(cells[1]).upper()
        if not ID_RE.match(ident) or not SEV_RE.match(sev_cell):
            continue
        location = norm(cells[2]) if len(cells) > 2 else ""
        finding = norm(cells[3]) if len(cells) > 3 else ""
        trigger = norm(cells[4]) if len(cells) > 4 else ""
        fix = norm(cells[5]) if len(cells) > 5 else ""
        match = LOC_RE.match(location)
        rows.append(
            {
                "id": ident,
                "sev": SEV_RE.match(sev_cell).group(1),
                "sev_label": sev_cell,
                "location": location,
                "path": (match.group("path").strip() if match else ""),
                "line": (int(match.group("line")) if match else 0),
                "symbol": (match.group("sym") or "").strip() if match else "",
                "finding": finding,
                "trigger": trigger,
                "fix": fix,
                "lane": lane,
            }
        )

    return {
        "lane": lane,
        "header": header,
        "coverage": coverage,
        "not_checked": not_checked,
        "rows": rows,
        "usable": header and coverage is not None,
    }


def signature(row: dict, lane_set_size: int) -> str:
    """Exact identity of a finding: location plus the sentence's digest.

    Used for dedupe bookkeeping. NOT used by the loop guard on its own: dogfooding showed
    the same verified SEV2 at the same line reported in two rounds with different wording,
    which hashes to a different signature and so escaped the guard entirely.
    """
    digest = hashlib.sha256(row["finding"].lower().encode()).hexdigest()[:12]
    return f"{row['path']}:{row['line']}:{digest}"


def lineprint(row: dict) -> str:
    """Location identity: what the loop guard and the `seen` count actually use.

    Deliberately ignores both the wording and the severity. Both are unstable across
    rounds — observed: one lane graded a seam SEV2 then stopped reporting it, while the
    other reported the same seam at SEV4 in both rounds — and "the fix did not take" is a
    question about the location, not about how it was phrased. Two genuinely different
    defects on one line across rounds would trip it; the cost of that is handing a change
    set to a human, which is the direction this gate errs in.
    """
    if not row["path"]:
        return f"noloc:{signature(row, 0)}"
    return f"{row['path']}:{row['line']}"


# --- ledger ------------------------------------------------------------------


def work_dir(args: argparse.Namespace, repo: str) -> Path:
    """Where review evidence lives: <repo>/review-work unless overridden."""
    if args.work_dir:
        return Path(args.work_dir).expanduser().resolve()
    return Path(repo) / "review-work"


def today() -> str:
    return time.strftime("%Y-%m-%d")


def ledger_path(args: argparse.Namespace, work: Path) -> Path:
    """One JSONL per day: review-work/<YYYY-MM-DD>.jsonl."""
    if args.ledger:
        return Path(args.ledger).expanduser()
    return work / f"{today()}.jsonl"


def ensure_ignored(repo: str, work: Path) -> str:
    """Make sure the work folder can never be committed, and say how.

    Written to `.git/info/exclude` rather than a tracked `.gitignore`: the gate runs in
    repositories that are not ours, and editing a tracked file on someone's behalf is not
    a review's business. The effect (`git status` stays clean) is identical; only the
    clone sees it.
    """
    probe = work / f"{today()}.jsonl"
    inside = run(["git", "-C", repo, "check-ignore", "-q", "--", str(probe)]).returncode == 0
    if inside:
        return "already-ignored"

    try:
        rel = work.relative_to(Path(repo))
        pattern = f"/{rel.as_posix()}/"
    except ValueError:
        pattern = f"{work}/"  # outside the repo: ignore by absolute path

    exclude = Path(git(repo, "rev-parse", "--git-path", "info/exclude"))
    if not exclude.is_absolute():
        exclude = Path(repo) / exclude
    exclude.parent.mkdir(parents=True, exist_ok=True)
    existing = exclude.read_text() if exclude.exists() else ""
    if pattern not in existing.split():
        with exclude.open("a") as handle:
            if existing and not existing.endswith("\n"):
                handle.write("\n")
            handle.write(f"# swarm-gate review evidence\n{pattern}\n")

    if run(["git", "-C", repo, "check-ignore", "-q", "--", str(probe)]).returncode == 0:
        return f"ignored via {pattern}"
    return "NOT IGNORED — review-work will show as untracked"


def read_prior(work: Path, change_set: str) -> list[dict]:
    """Every prior round for this change set, across all date files.

    Reading only today's file would reset the round budget and the loop guard whenever a
    fix loop crossed midnight — the counters would look at an empty history and restart.
    Date filenames sort chronologically, and within a file records are appended in order.
    """
    if not work.is_dir():
        return []
    records: list[dict] = []
    for path in sorted(work.glob("*.jsonl")):
        records.extend(r for r in read_ledger(path) if r.get("change_set") == change_set)
    return records


def read_ledger(path: Path) -> list[dict]:
    if not path.exists():
        return []
    records = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except json.JSONDecodeError:
            continue  # a torn last line must not make the gate unusable
    return records


def append_ledger(path: Path, record: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")


# --- policy ------------------------------------------------------------------


REPRO_VERIFIED = re.compile(r"(?<!un)verified\b", re.IGNORECASE)
REPRO_UNVERIFIED = re.compile(r"\bunverified\b", re.IGNORECASE)


def repro_state(row: dict) -> str:
    """Did the lane execute the trigger, or only argue for it?

    The lane contract already requires it to mark anything it could not execute as
    UNVERIFIED, so this reads a marker the lane was told to write rather than inventing
    one. 'unverified' wins over 'verified' because the latter is a substring of the
    former.
    """
    text = " ".join((row.get("finding") or "", row.get("trigger") or "", row.get("fix") or ""))
    if REPRO_UNVERIFIED.search(text):
        return "unverified"
    if REPRO_VERIFIED.search(text):
        return "verified"
    return "unknown"


def record_locations(record: dict) -> set[str]:
    """Locations a prior round flagged as blocking.

    Derived from `findings` when the record predates the `lineprints` field. Without this
    an older ledger is silently invisible to the guard — observed: rounds 1 and 2 recorded
    before the field existed, so round 3 labelled a twice-flagged line as `single-sample`
    and the guard stayed quiet while the same defect was reported for the third time.
    """
    if record.get("lineprints"):
        return set(record["lineprints"])
    derived = set()
    for finding in record.get("findings") or []:
        if str(finding.get("sev")) in ("1", "2"):
            if finding.get("path"):
                derived.add(f"{finding['path']}:{finding['line']}")
            else:
                derived.add("noloc:?")
    return derived


def seen_count(row: dict, prior: list[dict]) -> int:
    """How many rounds this LOCATION has been flagged in, including this one."""
    spot = lineprint(row)
    sig = signature(row, 0)
    return 1 + sum(
        1
        for record in prior
        if spot in record_locations(record) or sig in set(record.get("signatures") or [])
    )


def provenance(row: dict, prior: list[dict]) -> str:
    """A label, not a dismissal.

    A finding that nobody executed and no second sample repeated is the class that might
    be noise. It is still reported and still blocks: a false positive costs one look at a
    named file:line, a false negative ships the defect.
    """
    state = repro_state(row)
    seen = seen_count(row, prior)
    if state == "verified":
        return "verified"
    if seen >= 2:
        return f"repeated x{seen}"
    return "single-sample, unexecuted" if state == "unverified" else "single-sample"


def diff_fingerprint(repo: str, base: str) -> str:
    """Identity of the change under review, including files git diff would not show.

    `git diff` omits untracked files, so a new file added without staging would leave the
    fingerprint unchanged — and a later clean round would then look like a fix of
    unchanged code. `git status --porcelain` carries the untracked names.
    """
    diff = run(["git", "-C", repo, "diff", base])
    status = run(["git", "-C", repo, "status", "--porcelain"])
    return hashlib.sha256((diff.stdout + "\0" + status.stdout).encode()).hexdigest()[:16]


def decide(
    rows: list[dict],
    prior: list[dict],
    max_rounds: int,
    sig_limit: int,
    diff_sha: str = "",
) -> tuple[int, str, list[str]]:
    """Map findings plus history onto (exit code, verdict, tripped signatures)."""
    blocking = [r for r in rows if r["sev"] in ("1", "2")]
    if not blocking:
        # A clean verdict on a diff that has not moved since a blocking round is not a
        # fix: it is the reviewer sampling differently. Certifying that is the one error a
        # gate must not make, so it gets its own exit code instead of a quiet 0.
        for record in reversed(prior):
            if record.get("exit") in (1, 3, 4) and record.get("diff_sha") == diff_sha and diff_sha:
                return (
                    6,
                    f"clean on an unchanged diff (blocking in round {record.get('round')}, diff unchanged) "
                    "- the reviewer is not reproducible, so this is not a pass",
                    [],
                )
        return 0, "clean", []

    current = {lineprint(r) for r in blocking}
    tripped = []
    if sig_limit > 1:
        for spot in current:
            consecutive = 1
            for record in reversed(prior):
                if spot in record_locations(record):
                    consecutive += 1
                else:
                    break
            if consecutive >= sig_limit:
                tripped.append(spot)

    round_no = len(prior) + 1
    if tripped:
        return 3, f"loop guard: {len(tripped)} location(s) still flagged after {sig_limit} rounds ({', '.join(sorted(tripped))})", tripped
    if max_rounds and round_no > max_rounds:
        return 4, f"round budget exhausted ({max_rounds} rounds)", []
    return 1, "sev1/2 present", []


# --- prepare -----------------------------------------------------------------


def prepare(repo: str, base: str, swarm_root: Path, dry_run: bool) -> dict:
    """Ask lane-prepare.sh for isolated per-lane worktrees; degrade honestly if not."""
    staged = run(["git", "-C", repo, "diff", "--cached", "--quiet"]).returncode != 0
    script = swarm_root / "scripts" / "lane-prepare.sh"

    if base != "HEAD":
        return {"mode": "shared", "degraded": "non-HEAD-base", "sha": base, "parent": base}
    if not staged:
        # lane-prepare materialises the INDEX or HEAD. Reviewing HEAD would review a tree
        # without the change, so shared mode is the honest choice here, not worktree mode.
        parent = git(repo, "rev-parse", base)
        return {"mode": "shared", "degraded": "unstaged-change", "sha": parent, "parent": parent}
    if not script.exists():
        parent = git(repo, "rev-parse", base)
        return {"mode": "shared", "degraded": "no-lane-prepare", "sha": parent, "parent": parent}
    if dry_run:
        return {"mode": "worktree", "degraded": "", "sha": "DRY-RUN", "parent": "DRY-RUN"}

    proc = run(["bash", str(script), "prepare", "--repo", repo], timeout=600)
    info: dict[str, str] = {}
    for line in proc.stdout.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            info[key.strip()] = value.strip()
    if proc.returncode != 0 or "MODE" not in info:
        return {
            "mode": "shared",
            "degraded": "lane-prepare-failed",
            "sha": git(repo, "rev-parse", base),
            "parent": git(repo, "rev-parse", base),
            "note": proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else "",
        }
    return {
        "mode": info["MODE"],
        "degraded": info.get("DEGRADED", ""),
        "sha": info.get("SHA", ""),
        "parent": info.get("PARENT", ""),
        "repo": info.get("REPO", repo),
        "cwd": {"correctness": info.get("CWD_CORRECTNESS", ""), "quality": info.get("CWD_QUALITY", "")},
    }


# --- report ------------------------------------------------------------------


def report(payload: dict, rows: list[dict], parsed: list[dict], as_json: bool) -> None:
    if as_json:
        print(json.dumps(payload, indent=2, sort_keys=True))
        return

    head = payload
    print(f"swarm-gate  {head['repo']}")
    print(
        f"change set {head['change_set'][:10]}  round {head['round']}"
        + (f"/{head['max_rounds']}" if head["max_rounds"] else "")
        + f"  mode {head['mode']}"
        + (f" ({head['degraded']})" if head["degraded"] else "")
    )
    counts = {sev: 0 for sev in "1234"}
    for row in rows:
        counts[row["sev"]] += 1
    print("  ".join(f"SEV{s} {counts[s]}" for s in "1234"))

    blocking = [r for r in rows if r["sev"] in ("1", "2")]
    advisory = [r for r in rows if r["sev"] in ("3", "4")]

    for title, group in (("blocking (SEV1-2)", blocking), ("your call (SEV3-4)", advisory)):
        if not group:
            continue
        print(f"\n-- {title} --")
        for row in sorted(group, key=lambda r: (r["sev"], r["path"], r["line"])):
            where = (
                f"{row['path']}:{row['line']}" + (f" ({row['symbol']})" if row["symbol"] else "")
                if row["path"]
                else "(no path:line given)"
            )
            prov = row.get("provenance", "")
            print(f"  {row['sev_label']} {where} [{row['lane']}]" + (f" [{prov}]" if prov else ""))
            if row["finding"]:
                print(f"     {row['finding']}")
            if row["trigger"]:
                print(f"     trigger: {row['trigger']}")

    print("\n-- coverage --")
    for lane in parsed:
        state = "unusable" if not lane["usable"] else ("clean" if not lane["rows"] else f"{len(lane['rows'])} row(s)")
        print(f"  {lane['lane']}: {state}")
        if lane["coverage"]:
            print(f"    read: {lane['coverage']}")
        if lane["not_checked"]:
            print(f"    skipped: {lane['not_checked']}")

    if head.get("ledger"):
        print(f"\nrecorded: {head['ledger']} ({head.get('ignore', '')})")
        if head.get("transcripts"):
            print(f"transcripts: {head['transcripts']}/")
    print(f"verdict: {head['verdict']} -> exit {head['exit']}")


# --- main --------------------------------------------------------------------


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="swarm-gate",
        description="Run the code-review-swarm lanes over a change and turn them into a verdict.",
    )
    parser.add_argument("--repo", default=".")
    parser.add_argument("--base", default="HEAD", help="diff base (default HEAD)")
    parser.add_argument("--scope", nargs="*", default=[], help="restrict the lanes to these paths")
    parser.add_argument("--lanes", default="correctness,quality")
    parser.add_argument("--max-rounds", type=int, default=3)
    parser.add_argument("--same-signature-limit", type=int, default=2)
    parser.add_argument("--timeout", type=float, default=900.0)
    parser.add_argument("--agents", default="", help="swarm agents dir (default: <swarm>/agents)")
    parser.add_argument("--ledger", default="", help="override the ledger file (default <work>/<date>.jsonl)")
    parser.add_argument("--work-dir", default="", help="evidence folder (default <repo>/review-work)")
    parser.add_argument("--no-transcripts", action="store_true", help="do not keep raw lane output")
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--dry-run", action="store_true", help="parse and report the plan, dispatch nothing")
    args = parser.parse_args(argv)

    try:
        repo = git(args.repo, "rev-parse", "--show-toplevel")
    except GateError as exc:
        print(f"swarm-gate: {exc.message}", file=sys.stderr)
        return exc.code

    swarm_root = Path(os.environ.get("CODE_REVIEW_SWARM", Path(__file__).resolve().parents[2] / "code-review-swarm"))
    agents_dir = Path(args.agents).expanduser() if args.agents else swarm_root / "agents"

    lanes = [lane.strip() for lane in args.lanes.split(",") if lane.strip()]
    unknown = [lane for lane in lanes if lane not in LANE_AGENT]
    if unknown:
        print(f"swarm-gate: unknown lane(s) {unknown}; known: {sorted(LANE_AGENT)}", file=sys.stderr)
        return 2
    if not shutil.which("pi") and not args.dry_run:
        print("swarm-gate: pi is not on PATH", file=sys.stderr)
        return 5

    # Nothing to review is not a pass; it is an empty question.
    if args.base == "HEAD" and run(["git", "-C", repo, "diff", "HEAD", "--quiet"]).returncode == 0:
        if not args.scope:
            print("swarm-gate: nothing to review — the working tree matches HEAD", file=sys.stderr)
            return 2

    change_set = git(repo, "rev-parse", args.base)
    prep = prepare(repo, args.base, swarm_root, args.dry_run)
    work = work_dir(args, repo)
    ledger = ledger_path(args, work)
    # --ledger is a complete override: if it moves the writes it must move the reads too,
    # or the round counter restarts at 1 and both the budget and the loop guard go quiet.
    if args.ledger:
        prior = [r for r in read_ledger(ledger) if r.get("change_set") == change_set]
    else:
        prior = read_prior(work, change_set)
    round_no = len(prior) + 1
    ignore_state = "dry-run" if args.dry_run else ensure_ignored(repo, work)
    transcript_dir = None
    if not args.no_transcripts and not args.dry_run:
        transcript_dir = work / today()

    if args.dry_run:
        payload = {
            "repo": repo,
            "change_set": change_set,
            "round": round_no,
            "max_rounds": args.max_rounds,
            "mode": prep["mode"],
            "degraded": prep.get("degraded", ""),
            "lanes": lanes,
            "work_dir": str(work),
            "ledger": str(ledger),
            "dry_run": True,
            "verdict": "dry-run",
            "exit": 0,
        }
        report(payload, [], [], args.json)
        return 0

    prompt = lane_prompt(prep["mode"], prep.get("sha", change_set), prep.get("parent", change_set), args.base, args.scope)
    stem = f"{change_set[:8]}-r{round_no}"
    jobs = []
    for lane in lanes:
        model, body = load_agent(agents_dir, lane)
        cwd = (prep.get("cwd") or {}).get(lane) or repo
        jobs.append((lane, model, body, cwd))

    results = []
    with ThreadPoolExecutor(max_workers=len(jobs)) as pool:
        with tempfile.TemporaryDirectory(prefix="swarm-gate.") as tmp:
            futures = [
                pool.submit(
                    dispatch_lane,
                    lane,
                    model,
                    body,
                    cwd,
                    prompt,
                    args.timeout,
                    Path(tmp),
                    transcript_dir,
                    stem,
                )
                for lane, model, body, cwd in jobs
            ]
            for future in futures:
                results.append(future.result())

    parsed = [parse_lane(r["lane"], r.get("text", "")) for r in results]
    failures = [r for r in results if not r["ok"]]
    unusable = [p for p in parsed if not p["usable"]]

    rows: list[dict] = [row for p in parsed for row in p["rows"]]
    # Dedupe only when two lanes cite the same path:line at the same severity. A row with
    # no parsable location must NOT collapse: `:0` is not a shared location, and two
    # distinct location-less findings are not the same finding (the live probe hit this —
    # a staged __pycache__ artifact came back without a path).
    merged: dict[tuple, dict] = {}
    for row in rows:
        if row["path"]:
            key = (row["sev"], row["path"], row["line"])
        else:
            key = (row["sev"], "", 0, signature(row, 0))
        if key in merged:
            merged[key]["lane"] = "both"
            continue
        merged[key] = row
    rows = sorted(merged.values(), key=lambda r: (r["sev"], r["path"], r["line"]))

    diff_sha = diff_fingerprint(repo, args.base)
    for row in rows:
        row["provenance"] = provenance(row, prior)
        row["repro"] = repro_state(row)
        row["seen"] = seen_count(row, prior)

    exit_code, verdict, tripped = decide(rows, prior, args.max_rounds, args.same_signature_limit, diff_sha)
    if failures or unusable:
        # A lane that never reported cannot support a clean verdict.
        exit_code = 5
        verdict = "lane unusable: " + "; ".join(
            [f"{f['lane']} {f['reason']}" for f in failures]
            + [f"{p['lane']} {'no table' if not p['header'] else 'no COVERAGE line'}" for p in unusable]
        )

    payload = {
        "repo": repo,
        "change_set": change_set,
        "sha": prep.get("sha", change_set),
        "parent": prep.get("parent", ""),
        "round": round_no,
        "max_rounds": args.max_rounds,
        "mode": prep["mode"],
        "degraded": prep.get("degraded", ""),
        "lanes": lanes,
        "work_dir": str(work),
        "ledger": str(ledger),
        "ignore": ignore_state,
        "transcripts": (
            str(transcript_dir) if transcript_dir else ""
        ),
        "models": {r["lane"]: r["model"] for r in results},
        "elapsed": {r["lane"]: round(r.get("elapsed", 0), 1) for r in results},
        "findings": rows,
        "diff_sha": diff_sha,
        "signatures": sorted({signature(r, 0) for r in rows if r["sev"] in ("1", "2")}),
        "lineprints": sorted({lineprint(r) for r in rows if r["sev"] in ("1", "2")}),
        "tripped": tripped,
        "coverage": {p["lane"]: {"usable": p["usable"], "coverage": p["coverage"], "not_checked": p["not_checked"]} for p in parsed},
        "verdict": verdict,
        "exit": exit_code,
    }

    if not args.dry_run:
        record = {k: payload[k] for k in ("repo", "change_set", "sha", "parent", "round", "mode", "degraded", "lanes", "models", "signatures", "lineprints", "verdict", "exit", "diff_sha")}
        record["ts"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        record["findings"] = [{"sev": r["sev"], "path": r["path"], "line": r["line"], "lane": r["lane"]} for r in rows]
        append_ledger(ledger, record)

    report(payload, rows, parsed, args.json)
    return exit_code


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
