#!/usr/bin/env node
// selftest.mjs — exercise the vendored subagent extension's LOCAL changes, no pi required.
//
//   node selftest.mjs
//
// What is under test is only what this package changed relative to pi's example:
// the package-relative agent directory (so `pi install` ships a usable `sysdv`),
// the `write_scope` frontmatter, and the write-scope post-check. Upstream process
// spawning, streaming, and rendering are exercised by pi itself, not here.

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = (() => {
	try {
		return path.dirname(fileURLToPath(import.meta.url));
	} catch {
		return process.cwd();
	}
})();
const PKG_AGENTS = path.resolve(HERE, "..", "..", "agents");
process.env.PI_SUBAGENT_PACKAGE_AGENTS = PKG_AGENTS;

let failures = 0;
const ok = (name, cond, detail = "") => {
	if (cond) {
		console.log(`  ok    ${name}`);
	} else {
		failures += 1;
		console.log(`  FAIL  ${name}${detail ? ` — ${detail}` : ""}`);
	}
};

const agentsMod = await import(path.join(HERE, "agents.ts"));
const toolMod = await import(path.join(HERE, "index.ts"));

// --- package-relative discovery --------------------------------------------
console.log("subagent selftest");

ok(
	"the package's own agents dir is resolved, not ~/.pi/agent",
	agentsMod.packageAgentsDir() === PKG_AGENTS,
	agentsMod.packageAgentsDir(),
);

const emptyCwd = mkdtempSync(path.join(tmpdir(), "subagent-cwd-"));
const discovery = agentsMod.discoverAgents(emptyCwd, "user");
const sysdv = discovery.agents.find((a) => a.name === "sysdv");
ok("sysdv is discovered with no install step", Boolean(sysdv), JSON.stringify(discovery.agents.map((a) => a.name)));
ok("sysdv is labelled as coming from the package", sysdv?.source === "package", String(sysdv?.source));
ok("sysdv declares its write scope", Boolean(sysdv?.writeScope?.includes("tests")), JSON.stringify(sysdv?.writeScope));
ok("a shipped agent carries its system prompt", (sysdv?.systemPrompt ?? "").length > 100);

// A user's own agent of the same name must win over the shipped one.
const fakeHome = mkdtempSync(path.join(tmpdir(), "subagent-home-"));
mkdirSync(path.join(fakeHome, "agents"), { recursive: true });
writeFileSync(
	path.join(fakeHome, "agents", "sysdv.md"),
	"---\nname: sysdv\ndescription: mine\n---\n\nlocal override\n",
);
const prevHome = process.env.PI_CODING_AGENT_DIR;
process.env.PI_CODING_AGENT_DIR = fakeHome;
const overridden = agentsMod.discoverAgents(emptyCwd, "user").agents.find((a) => a.name === "sysdv");
ok("a user agent of the same name wins", overridden?.source === "user", String(overridden?.source));
if (prevHome === undefined) delete process.env.PI_CODING_AGENT_DIR;
else process.env.PI_CODING_AGENT_DIR = prevHome;
rmSync(fakeHome, { recursive: true, force: true });

// --- porcelain parsing + scope check ---------------------------------------
const porcelain = [
	" M src/app.py",
	"?? tests/test_new.py",
	"R  tests/old_test.py -> tests/test_renamed.py",
	'?? "tests/with space.py"',
	"?? conftest.py",
].join("\n");
const parsed = toolMod.parsePorcelainPaths(porcelain);
ok("porcelain paths are extracted", parsed.includes("src/app.py") && parsed.includes("tests/test_new.py"));
ok("a rename yields the landed path", parsed.includes("tests/test_renamed.py") && !parsed.includes("tests/old_test.py"));
ok("quoted paths are unquoted", parsed.includes("tests/with space.py"), JSON.stringify(parsed));

const scope = ["tests", "conftest.py"];
const outside = toolMod.pathsOutsideScope(parsed, scope);
ok("an in-scope write is not reported", !outside.includes("tests/test_new.py"));
ok("an out-of-scope write is reported", outside.includes("src/app.py"), JSON.stringify(outside));
ok("a scope entry matches a file as well as a directory", !outside.includes("conftest.py"));
ok("a lookalike prefix is not in scope", toolMod.pathsOutsideScope(["tests_extra/x.py"], scope).length === 1);

// Running the suite writes caches; those must never fail a lane.
for (const artifact of [
	"src/__pycache__/app.cpython-312.pyc",
	"tests/__pycache__/test_x.cpython-312-pytest-9.2.0.pyc",
	".pytest_cache/v/cache/nodeids",
	"node_modules/left-pad/index.js",
	".venv/lib/python3.12/site-packages/x.py",
	"pkg.egg-info/PKG-INFO",
]) {
	ok(`derived artifact is ignored: ${artifact}`, toolMod.isDerivedArtifact(artifact));
}
for (const real of ["src/helper.py", "tests/test_add.py", "dist/bundle.js"]) {
	ok(`a real file is not ignored: ${real}`, !toolMod.isDerivedArtifact(real));
}

// --- end to end against a real git tree ------------------------------------
const repo = mkdtempSync(path.join(tmpdir(), "subagent-repo-"));
const git = (...args) => execFileSync("git", args, { cwd: repo, encoding: "utf8" });
git("init", "-q", ".");
git("config", "user.email", "t@invalid");
git("config", "user.name", "t");
git("config", "commit.gpgsign", "false");
mkdirSync(path.join(repo, "tests"), { recursive: true });
mkdirSync(path.join(repo, "src"), { recursive: true });
writeFileSync(path.join(repo, "src", "app.py"), "value = 1\n");
git("add", "-A");
git("commit", "-qm", "init");

// checkWriteScope is not exported (it shells out); drive the same primitives the
// tool uses so the assertion is about behaviour, not about a private name.
const statusOf = () =>
	execFileSync("git", ["status", "--porcelain=v1", "-uall"], { cwd: repo, encoding: "utf8" });

ok("a clean worktree reports nothing", toolMod.pathsOutsideScope(toolMod.parsePorcelainPaths(statusOf()), ["tests"]).length === 0);
writeFileSync(path.join(repo, "tests", "test_ok.py"), "def test_x():\n    assert True\n");
ok(
	"a test-only write stays inside scope",
	toolMod.pathsOutsideScope(toolMod.parsePorcelainPaths(statusOf()), ["tests"]).length === 0,
);
writeFileSync(path.join(repo, "src", "sneak.py"), "x = 1\n");
const bad = toolMod.pathsOutsideScope(toolMod.parsePorcelainPaths(statusOf()), ["tests"]);
ok("a source write is caught after the fact", bad.includes("src/sneak.py"), JSON.stringify(bad));

rmSync(repo, { recursive: true, force: true });
rmSync(emptyCwd, { recursive: true, force: true });

console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
