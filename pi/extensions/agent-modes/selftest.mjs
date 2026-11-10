#!/usr/bin/env node
// selftest.mjs — exercise the mode guard against the real extension, no pi required.
//
//   node selftest.mjs
//
// Implements just enough of the ExtensionAPI to drive session_start / tool_call /
// tool_result, then asserts the behaviour the docs promise. Node >= 23 runs the .ts
// entry directly (type stripping), so there is no build step and no test framework.

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";

const HERE = path.dirname(new URL(import.meta.url).pathname);
// Load the profile from THIS checkout, not from a live ~/.pi/agent install.
process.env.PI_AGENT_MODES_DIR = HERE;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));
let failures = 0;
const ok = (name, cond, detail = "") => {
	if (cond) {
		console.log(`  ok    ${name}`);
	} else {
		failures += 1;
		console.log(`  FAIL  ${name}${detail ? ` — ${detail}` : ""}`);
	}
};

// --- harness ---------------------------------------------------------------
function makePi(state) {
	const handlers = new Map();
	const shortcuts = new Map();
	const pi = {
		on: (name, fn) => handlers.set(name, fn),
		registerFlag() {},
		registerCommand() {},
		registerShortcut: (key, def) => shortcuts.set(key, def),
		getFlag: () => state.flag ?? "",
		getActiveTools: () => [...state.active],
		setActiveTools: (tools) => {
			state.active = [...tools];
		},
		setModel: async (model) => {
			state.model = model.id;
			return true;
		},
		appendEntry: (type, data) => state.entries.push({ type, data }),
	};
	const ctx = {
		hasUI: true,
		sessionManager: { getEntries: () => state.sessionEntries },
		model: { id: "start-model" },
		modelRegistry: {
			find: (_provider, id) => (id.startsWith("missing") ? undefined : { id, provider: "test" }),
			getAvailable: () => [],
		},
		ui: {
			setStatus() {},
			notify: (msg, level) => state.toasts.push({ msg, level }),
			theme: { fg: (_c, s) => s },
			select: async () => undefined,
		},
	};
	return { pi, ctx, handlers, shortcuts };
}

// A throwaway git repo so the drift audit has a real tree to snapshot.
function makeRepo() {
	const dir = mkdtempSync(path.join(tmpdir(), "agent-modes-"));
	const git = (...args) => execFileSync("git", args, { cwd: dir, encoding: "utf8" });
	git("init", "-q", ".");
	git("config", "user.email", "t@invalid");
	git("config", "user.name", "t");
	git("config", "commit.gpgsign", "false");
	mkdirSync(path.join(dir, "tests"), { recursive: true });
	mkdirSync(path.join(dir, "src"), { recursive: true });
	mkdirSync(path.join(dir, "docs"), { recursive: true });
	writeFileSync(path.join(dir, "src", "app.py"), "value = 1\n");
	writeFileSync(path.join(dir, "tests", "test_app.py"), "def test_x():\n    assert True\n");
	writeFileSync(path.join(dir, "docs", "ledger.md"), "# ledger\n");
	writeFileSync(path.join(dir, "pyproject.toml"), "[tool.pytest.ini_options]\naddopts = \"\"\n");
	git("add", "-A");
	git("commit", "-qm", "init");
	return { dir, git };
}

const repo = makeRepo();
const startCwd = process.cwd();
process.chdir(repo.dir);

const state = {
	flag: "",
	active: ["read", "bash", "edit", "write", "grep", "find", "ls", "memory_search", "mcp", "todo"],
	model: undefined,
	entries: [],
	toasts: [],
	sessionEntries: [],
};
const { pi, ctx, handlers, shortcuts } = makePi(state);
const ext = await import(path.join(HERE, "index.ts"));
ext.default(pi);

// --- scenarios -------------------------------------------------------------
console.log("agent-modes selftest");

await handlers.get("session_start")({}, ctx);
await tick(); // session_start fires setMode without awaiting it
ok("fresh session enters the default mode", state.entries.at(-1)?.data?.mode === "oracle");
ok(
	"no model configured leaves the session model alone",
	state.model === undefined,
	`model=${state.model}`,
);
ok("oracle has no write tools", !state.active.includes("edit") && !state.active.includes("write"));
ok("oracle keeps read-only extensions", state.active.includes("memory_search") && state.active.includes("read"));

// Overrides layer over the shipped profile, so a user never edits inside the package.
const overrideFile = path.join(repo.dir, "agent-modes.override.json");
writeFileSync(
	overrideFile,
	JSON.stringify({ modes: { oracle: { model: "vendor/thing" }, build: { writeDeny: ["only_this"] } } }),
);
process.env.PI_AGENT_MODES_CONFIG = overrideFile;
await handlers.get("session_start")({}, ctx);
await tick();
ok("an override file supplies a model", state.model === "thing", `model=${state.model}`);

writeFileSync(overrideFile, JSON.stringify({ modes: { oracle: { model: "missing-model" } } }));
state.toasts.length = 0;
await handlers.get("session_start")({}, ctx);
await tick();
ok(
	"an unknown model warns instead of failing the switch",
	state.toasts.some((t) => t.level === "warning") && state.entries.at(-1)?.data?.mode === "oracle",
	JSON.stringify(state.toasts),
);

delete process.env.PI_AGENT_MODES_CONFIG;
await handlers.get("session_start")({}, ctx);
await tick();

const call = (toolName, input, toolCallId = "c1") => handlers.get("tool_call")({ toolName, input, toolCallId });

// A patch to one key must not erase the rest of that mode's shipped profile.
writeFileSync(overrideFile, JSON.stringify({ modes: { build: { writeDeny: ["only_this"] } } }));
process.env.PI_AGENT_MODES_CONFIG = overrideFile;
await handlers.get("session_start")({}, ctx);
await tick();
await shortcuts.get("ctrl+3").handler(ctx); // build
ok(
	"a partial override keeps the rest of the mode's profile",
	state.active.includes("edit") && state.active.includes("write"),
	JSON.stringify(state.active),
);
ok("a replaced writeDeny no longer blocks the old paths", (await call("write", { path: "tests/test_app.py", content: "x" })) === undefined);
delete process.env.PI_AGENT_MODES_CONFIG;
await handlers.get("session_start")({}, ctx);
await tick();

let r = await call("write", { path: "src/app.py", content: "x" });
ok("oracle refuses a write", r?.block === true);
ok("oracle refusal names the mode", String(r?.reason).includes("[oracle]"), String(r?.reason));

await shortcuts.get("ctrl+2").handler(ctx); // plan
r = await call("write", { path: "src/app.py", content: "x" });
ok("plan refuses a write outside its scope", r?.block === true);
ok("plan scope refusal names the allowed paths", String(r?.reason).includes("docs"), String(r?.reason));
r = await call("write", { path: "docs/ledger.md", content: "# ledger\n" });
ok("plan writes inside its scope", r === undefined);
r = await call("write", { path: "/etc/passwd", content: "x" });
ok("plan refuses an absolute path outside the tree", r?.block === true);

await shortcuts.get("ctrl+3").handler(ctx); // build
r = await call("write", { path: "src/app.py", content: "value = 2\n" });
ok("build writes source", r === undefined);
for (const locked of ["tests/test_app.py", "pyproject.toml", "conftest.py"]) {
	r = await call("write", { path: locked, content: "x" });
	ok(`build refuses the frozen surface: ${locked}`, r?.block === true, String(r?.reason ?? ""));
}
r = await call("edit", { path: "tests/nested/test_deep.py", oldText: "a", newText: "b" });
ok("build refuses a new test file under a subdirectory", r?.block === true);

// Bash policy on the oracle-mode profile.
await shortcuts.get("ctrl+1").handler(ctx); // oracle
const allowed = ["rg -n value src/", "git log --oneline -3", "pytest tests/", "make test", "ruff check src/", "black --check ."];
const refused = ["rm -rf src", "echo x > src/new.py", "cat a >> b", "git commit -am wip", "pip install numpy", "black .", "pytest --snapshot-update", "python3 scripts/gen_base.py"];
for (const cmd of allowed) {
	r = await call("bash", { command: cmd });
	ok(`allows: ${cmd}`, r === undefined, String(r?.reason ?? ""));
}
for (const cmd of refused) {
	r = await call("bash", { command: cmd });
	ok(`refuses: ${cmd}`, r?.block === true);
}

// Tracked-tree audit: an allowed command that changes a tracked file is reported.
const result = (id, toolName = "bash") =>
	handlers.get("tool_result")({ toolName, toolCallId: id, content: [{ type: "text", text: "out" }], isError: false }, ctx);

await call("bash", { command: "pytest tests/" }, "audit-1");
const drift = await result("audit-1");
ok("clean command adds no audit text", drift === undefined);

await call("bash", { command: "pytest tests/" }, "audit-2");
appendFileSync(path.join(repo.dir, "src", "app.py"), "# fixture rewrote me\n");
const drifted = await result("audit-2");
ok("tracked-file change is reported", Boolean(drifted), "no audit appended");
ok("audit names the file", String(drifted?.content?.at(-1)?.text ?? "").includes("src/app.py"));
ok("audit raises a toast", state.toasts.some((t) => t.level === "warning"));

process.chdir(startCwd);
rmSync(repo.dir, { recursive: true, force: true });

console.log(`\n${failures === 0 ? "all passed" : `${failures} failed`}`);
process.exit(failures === 0 ? 0 : 1);
