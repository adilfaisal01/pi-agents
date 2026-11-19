#!/usr/bin/env node
// selftest.mjs — exercise the vendored subagent extension's LOCAL changes, no pi required.
//
//   node selftest.mjs
//
// What is under test is only what this package changed relative to pi's example:
// the package-relative agent directory (so `pi install` can ship agents), the
// `write_scope` frontmatter, and the write-scope post-check. Upstream process
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
const DEFAULT_AGENTS_ROOT = path.resolve(HERE, "agents");

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

// The default root is this package's own agents/, resolved from the module's location so
// it survives wherever pi installed the package — npm cache, git checkout, release dir.
delete process.env.PI_SUBAGENT_PACKAGE_AGENTS;
ok(
	"the package's own agents dir is resolved, not ~/.pi/agent",
	agentsMod.packageAgentsDirs().includes(DEFAULT_AGENTS_ROOT),
	JSON.stringify(agentsMod.packageAgentsDirs()),
);

// LOCAL 5: a bundle declares its agents directories in the manifest it shares with the
// extension, so publishing one npm package does not mean copying the agent files.
const bundleRoot = mkdtempSync(path.join(tmpdir(), "subagent-bundle-"));
mkdirSync(path.join(bundleRoot, "swarm", "agents"), { recursive: true });
writeFileSync(
	path.join(bundleRoot, "package.json"),
	JSON.stringify({ name: "fixture-bundle", pi: { agents: ["./swarm/agents"] } }),
);
const declared = agentsMod.declaredAgentDirs(bundleRoot);
ok(
	"pi.agents is read from the manifest, package-relative",
	declared.length === 1 && declared[0] === "./swarm/agents",
	JSON.stringify(declared),
);
ok(
	"a manifest without pi.agents declares nothing",
	agentsMod.declaredAgentDirs(path.join(bundleRoot, "swarm")).length === 0,
	JSON.stringify(agentsMod.declaredAgentDirs(path.join(bundleRoot, "swarm"))),
);

// A fixture agent stands in for whatever a consumer ships. The test must not depend on
// another project's agent files existing — that coupling is what this package removes.
const pkgAgents = mkdtempSync(path.join(tmpdir(), "subagent-pkg-"));
writeFileSync(
	path.join(pkgAgents, "fixture.md"),
	[
		"---",
		"name: fixture",
		"description: fixture agent for the selftest",
		"tools: read, grep",
		"write_scope: tests, conftest.py",
		"---",
		"",
		"You are a fixture agent. ".repeat(8),
		"",
	].join("\n"),
);
process.env.PI_SUBAGENT_PACKAGE_AGENTS = pkgAgents;

const emptyCwd = mkdtempSync(path.join(tmpdir(), "subagent-cwd-"));
const discovery = agentsMod.discoverAgents(emptyCwd, "user");
const fixture = discovery.agents.find((a) => a.name === "fixture");
ok(
	"an agent shipped in the package root is discovered with no install step",
	Boolean(fixture),
	JSON.stringify(discovery.agents.map((a) => a.name)),
);
ok("it is labelled as coming from the package", fixture?.source === "package", String(fixture?.source));
ok("it declares its write scope", Boolean(fixture?.writeScope?.includes("tests")), JSON.stringify(fixture?.writeScope));
ok("it carries its system prompt", (fixture?.systemPrompt ?? "").length > 100);

// --- LOCAL 6: the role→model map -------------------------------------------
// Pinned to a path we control before any discovery runs: a machine that happens to have a
// ~/.pi/agent/subagent-models.json must not change this suite's verdict.
const mapDir = mkdtempSync(path.join(tmpdir(), "subagent-models-"));
const userMapFile = path.join(mapDir, "user-map.json");
process.env.PI_SUBAGENT_MODEL_MAP = userMapFile;
const writeMap = (file, obj) => writeFileSync(file, JSON.stringify(obj));
const modelOf = (cwd, name) => agentsMod.discoverAgents(cwd, "user").agents.find((a) => a.name === name);

// A second fixture whose frontmatter pins a model, so precedence can be observed.
writeFileSync(
	path.join(pkgAgents, "fixture-pinned.md"),
	"---\nname: fixture-pinned\ndescription: pinned in frontmatter\nmodel: vendor/frontmatter-model\n---\n\npinned agent\n",
);

ok(
	"an unmapped agent with no frontmatter model inherits the dispatcher",
	modelOf(emptyCwd, "fixture")?.model === undefined,
	String(modelOf(emptyCwd, "fixture")?.model),
);
ok(
	"frontmatter is reported as the model's source",
	modelOf(emptyCwd, "fixture-pinned")?.modelSource === "frontmatter",
	String(modelOf(emptyCwd, "fixture-pinned")?.modelSource),
);

writeMap(userMapFile, { fixture: "vendor/user-map-model" });
let pinned = modelOf(emptyCwd, "fixture");
ok("the user map pins a model for a role", pinned?.model === "vendor/user-map-model", String(pinned?.model));
ok("the pin is attributed to the user layer", pinned?.modelSource === "user-map", String(pinned?.modelSource));
writeMap(userMapFile, { "fixture-pinned": "vendor/user-beats-frontmatter" });
pinned = modelOf(emptyCwd, "fixture-pinned");
ok(
	"a map entry beats the agent's own frontmatter",
	pinned?.model === "vendor/user-beats-frontmatter" && pinned?.modelSource === "user-map",
	`${pinned?.model} (${pinned?.modelSource})`,
);

// Project layer: `<nearest .pi>/subagent-models.json`, found by walking up from cwd.
const projectRoot = mkdtempSync(path.join(tmpdir(), "subagent-proj-"));
const projectCwd = path.join(projectRoot, "nested", "deeper");
mkdirSync(path.join(projectRoot, ".pi"), { recursive: true });
mkdirSync(projectCwd, { recursive: true });
writeMap(path.join(projectRoot, ".pi", "subagent-models.json"), { fixture: "vendor/project-map-model" });
ok(
	"the project map is found from a nested cwd",
	agentsMod.findNearestModelMap(projectCwd) === path.join(projectRoot, ".pi", "subagent-models.json"),
	String(agentsMod.findNearestModelMap(projectCwd)),
);
pinned = modelOf(projectCwd, "fixture");
ok("the project map beats the user map", pinned?.model === "vendor/project-map-model", String(pinned?.model));
ok("the pin is attributed to the project layer", pinned?.modelSource === "project-map", String(pinned?.modelSource));
ok(
	"an unknown name in a map is ignored",
	modelOf(projectCwd, "fixture-pinned")?.model === "vendor/user-beats-frontmatter",
	String(modelOf(projectCwd, "fixture-pinned")?.model),
);

// A broken map is a missing map, never a crash: discovery runs on every dispatch.
writeFileSync(userMapFile, "{ not json");
ok("a malformed user map pins nothing", modelOf(emptyCwd, "fixture")?.model === undefined);
writeFileSync(userMapFile, JSON.stringify({ fixture: 42, "": "vendor/x" }));
ok("a non-string or empty pin is dropped", modelOf(emptyCwd, "fixture")?.model === undefined);

writeMap(userMapFile, {});
rmSync(mapDir, { recursive: true, force: true });
rmSync(projectRoot, { recursive: true, force: true });
delete process.env.PI_SUBAGENT_MODEL_MAP;

// A user's own agent of the same name must win over the shipped one.
const fakeHome = mkdtempSync(path.join(tmpdir(), "subagent-home-"));
mkdirSync(path.join(fakeHome, "agents"), { recursive: true });
writeFileSync(
	path.join(fakeHome, "agents", "fixture.md"),
	"---\nname: fixture\ndescription: mine\n---\n\nlocal override\n",
);
const prevHome = process.env.PI_CODING_AGENT_DIR;
process.env.PI_CODING_AGENT_DIR = fakeHome;
const overridden = agentsMod.discoverAgents(emptyCwd, "user").agents.find((a) => a.name === "fixture");
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
rmSync(pkgAgents, { recursive: true, force: true });

console.log(failures === 0 ? "\nall passed" : `\n${failures} failed`);
process.exit(failures === 0 ? 0 : 1);
