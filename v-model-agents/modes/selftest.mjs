#!/usr/bin/env node
// selftest.mjs — exercise the mode guard against the real extension, no pi required.
//
//   node selftest.mjs
//
// Implements just enough of the ExtensionAPI to drive session_start / tool_call /
// tool_result, then asserts the behaviour the docs promise. Node >= 23 runs the .ts
// entry directly (type stripping), so there is no build step and no test framework.

import { execFileSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, appendFileSync, readFileSync, existsSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const HERE = path.dirname(fileURLToPath(import.meta.url));
// Load the profile from THIS checkout, not from a live ~/.pi/agent install.
process.env.PI_AGENT_MODES_DIR = HERE;
// Hermetic: the profile also merges ~/.pi/agent/agent-modes.json, so a real user config
// on this machine would leak into the assertions (a model set for every project makes
// "no model configured" false). Point HOME at a throwaway directory before any read.
const fakeHome = mkdtempSync(path.join(tmpdir(), "agent-modes-home-"));
process.env.HOME = fakeHome;
process.env.USERPROFILE = fakeHome;
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
		sendMessage: (message, options) => state.messages.push({ ...message, options }),
	};
	const ctx = {
		hasUI: true,
		isIdle: () => state.idle !== false,
		sessionManager: {
			getEntries: () => state.sessionEntries,
			// Mirrors pi's projection: message entries become their message, custom
			// messages become role "custom". The distinction matters — the restore
			// notice must not count this extension's own notices as conversation.
			buildSessionProjection: () => ({
				messages: state.sessionEntries.flatMap((e) => {
					if (e.type === "message") return [e.message];
					if (e.type === "custom_message") {
						return [{ role: "custom", customType: e.customType, content: e.content }];
					}
					return [];
				}),
			}),
		},
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
	mkdirSync(path.join(dir, "harness"), { recursive: true });
	mkdirSync(path.join(dir, ".claude", "hooks"), { recursive: true });
	writeFileSync(path.join(dir, "harness", "run-task.sh"), "#!/usr/bin/env bash\nexit 0\n");
	writeFileSync(path.join(dir, ".claude", "hooks", "deny.sh"), "#!/usr/bin/env bash\nexit 0\n");
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
	idle: true,
	active: ["read", "bash", "edit", "write", "grep", "find", "ls", "memory_search", "mcp", "todo"],
	model: undefined,
	entries: [],
	messages: [],
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

// The contract is a system-prompt SECTION, so pi can diff it and patch only that
// section on a switch, keeping the model's cached prefix and pi's own tool-change
// declarations. Returning a forced `systemPrompt` would replace the whole prompt
// for the run and drop every other system message, `toolsRemoved` included.
const startEvent = () => ({
	event: { systemPrompt: "base", systemPromptOptions: { sections: { preamble: "base" } } },
});
const firstRun = startEvent();
const forced = await handlers.get("before_agent_start")(firstRun.event, ctx);
ok("before_agent_start does not force a whole prompt", forced === undefined, JSON.stringify(forced));
const contract = firstRun.event.systemPromptOptions.sections["agent-mode"];
ok("the mode contract is a tagged section", typeof contract === "string", JSON.stringify(firstRun.event.systemPromptOptions.sections));
ok("the section states the write policy", String(contract).includes("read-only toward the repo"), String(contract));
ok("the section states the shell policy", String(contract).includes("allowlist"), String(contract));
ok("the section leaves pi's own sections alone", firstRun.event.systemPromptOptions.sections.preamble === "base");
ok("a fresh session says nothing in the conversation", state.messages.length === 0, JSON.stringify(state.messages));

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
await tick();
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
ok(
	"the refusal points at the real cycle key, not Tab",
	String(r?.reason).includes("alt+a"),
	String(r?.reason),
);

// Switching is enforced by the harness, but the MODEL has to be told: a notice
// lands in the conversation naming the permissions it just gained or lost.
state.messages.length = 0;
await shortcuts.get("ctrl+3").handler(ctx); // build
await tick();
const toBuild = state.messages.at(-1);
ok("a switch announces itself in the conversation", toBuild?.customType === "agent-modes", JSON.stringify(state.messages));
ok("the notice names both modes", String(toBuild?.content).includes("`oracle` → `build`"), String(toBuild?.content));
ok("the notice lists the tools that came back", String(toBuild?.content).includes("Tools added: edit"), String(toBuild?.content));
ok(
	"an idle switch persists at once and buys no turn",
	toBuild?.options?.deliverAs === undefined && toBuild?.options?.triggerTurn === undefined,
	JSON.stringify(toBuild?.options),
);

state.idle = false;
state.messages.length = 0;
await shortcuts.get("ctrl+1").handler(ctx); // back to oracle, mid-run
await tick();
const toOracle = state.messages.at(-1);
ok(
	"a mid-run switch steers instead of waiting for a prompt",
	toOracle?.options?.deliverAs === "steer",
	JSON.stringify(toOracle?.options),
);
ok("the notice names the tools that went away", String(toOracle?.content).includes("Tools removed: edit, write"), String(toOracle?.content));
ok("the notice supersedes earlier claims", String(toOracle?.content).includes("supersedes"), String(toOracle?.content));
ok(
	"the notice says the write permission is gone",
	String(toOracle?.content).includes("Writes: none"),
	String(toOracle?.content),
);
state.idle = true;
state.messages.length = 0;

// Key repeats arrive as one stdin chunk and pi dispatches each sequence synchronously,
// so two presses must land in the same tick and still advance two steps. Reading
// `current` here would alias both onto the same mode, because the queued switch has not
// updated it yet.
state.messages.length = 0;
await shortcuts.get("ctrl+3").handler(ctx); // build
await tick();
shortcuts.get("alt+a").handler(ctx); // → yolo, synchronous burst
shortcuts.get("alt+a").handler(ctx); // → forge
await tick();
ok(
	"two coalesced presses advance two steps",
	state.entries.at(-1)?.data?.mode === "forge",
	JSON.stringify(state.entries.map((e) => e.data?.mode)),
);
await shortcuts.get("ctrl+1").handler(ctx); // back to oracle
await tick();
state.messages.length = 0;

await shortcuts.get("ctrl+2").handler(ctx); // plan
await tick();
r = await call("write", { path: "src/app.py", content: "x" });
ok("plan refuses a write outside its scope", r?.block === true);
ok("plan scope refusal names the allowed paths", String(r?.reason).includes("docs"), String(r?.reason));
r = await call("write", { path: "docs/note.md", content: "# note\n" });
ok("plan writes inside its scope", r === undefined);
// The plan itself is the todo list; a file ledger is no longer part of the contract.
r = await call("write", { path: "ledger.md", content: "# ledger\n" });
ok("plan refuses the retired file ledger at the repo root", r?.block === true, String(r?.reason ?? ""));
r = await call("write", { path: "/etc/passwd", content: "x" });
ok("plan refuses an absolute path outside the tree", r?.block === true);

await shortcuts.get("ctrl+3").handler(ctx); // build
await tick();
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
await tick();
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

// --- forge mode: autonomous work, but never its own machinery ----------------
const forgeMode = JSON.parse(readFileSync(path.join(HERE, "config.json"), "utf8"));
ok("forge ships in the cycle order", forgeMode.order.includes("forge"), JSON.stringify(forgeMode.order));
ok(
	"forge ships a prompt contract",
	Boolean(forgeMode.modes?.forge?.promptFile) &&
		existsSync(path.join(HERE, forgeMode.modes.forge.promptFile)),
	String(forgeMode.modes?.forge?.promptFile),
);

await shortcuts.get("ctrl+5").handler(ctx); // forge
await tick();
ok("ctrl+5 reaches forge mode", state.entries.at(-1)?.data?.mode === "forge");
ok(
	"forge keeps the write tools",
	state.active.includes("edit") && state.active.includes("write"),
	JSON.stringify(state.active),
);
ok("forge guarantees the subagent tool", state.active.includes("subagent"));
r = await call("write", { path: "src/app.py", content: "value = 3\n" });
ok("forge writes source", r === undefined, String(r?.reason ?? ""));
for (const machinery of ["harness/run-task.sh", ".claude/hooks/deny.sh", ".beads/x.json", "gate/run-tests.sh"]) {
	r = await call("write", { path: machinery, content: "x" });
	ok(`forge refuses the machinery: ${machinery}`, r?.block === true, String(r?.reason ?? ""));
}
r = await call("write", { path: "harness/run-task.sh", content: "x" });
ok("forge refusal names the mode", String(r?.reason).includes("[forge]"), String(r?.reason));
ok(
	"forge refusal describes the machinery, not the test surface",
	String(r?.reason).includes("forge machinery") && !String(r?.reason).includes("frozen test surface"),
	String(r?.reason),
);
r = await call("bash", { command: "git commit -am wip" });
ok("forge leaves the shell unrestricted", r === undefined, String(r?.reason ?? ""));

// --- resume: a restore into a different mode has to announce itself ---------
// A resumed process starts with no mode of its own and takes one from the transcript
// or from --agent-mode, which wins over the persisted mode. The model's earlier
// permission claims are already in that transcript, so the restore announces itself
// too. Needs a fresh module instance — the shared one above still holds a mode.
let resumeCount = 0;
const resume = async ({ persisted, flag = "", active, conversation = true }) => {
	const sim = {
		flag,
		idle: true,
		// pi restores the transcript's tool loadout BEFORE session_start fires, so a
		// resumed oracle session starts with edit/write already filtered out.
		active: active ?? ["read", "bash", "edit", "write", "grep", "find", "ls"],
		model: undefined,
		entries: [],
		messages: [],
		toasts: [],
		sessionEntries: [
			{ type: "custom", customType: "agent-modes", data: { mode: persisted } },
			...(conversation ? [{ type: "message", message: { role: "user", content: "hi" } }] : []),
		],
	};
	const simPi = makePi(sim);
	// A fresh module instance per scenario (query strings make distinct ESM modules),
	// numbered so two scenarios sharing a (persisted, flag) pair never share state.
	const simExt = await import(`${path.join(HERE, "index.ts")}?resume=${++resumeCount}`);
	simExt.default(simPi.pi);
	await simPi.handlers.get("session_start")({}, simPi.ctx);
	await tick();
	return { state: sim, ...simPi };
};

const restoredRun = await resume({ persisted: "build", flag: "oracle" });
const restored = restoredRun.state;
ok(
	"a restore into a different mode announces itself as a restore",
	/^Mode restored:.*`oracle`.*last in `build`/.test(String(restored.messages.at(-1)?.content ?? "")),
	JSON.stringify(restored.messages.map((m) => m.content)),
);
ok("the restore records the mode it landed in", restored.entries.at(-1)?.data?.mode === "oracle");

const plainRun = await resume({ persisted: "oracle" });
ok("a plain resume says nothing", plainRun.state.messages.length === 0, JSON.stringify(plainRun.state.messages));

// A transcript where the only non-system entries are this extension's own mode notices
// is not a conversation: nothing was said about permissions, so nothing needs superseding.
const noticesOnly = await resume({ persisted: "build", flag: "oracle", conversation: false });
ok(
	"a transcript of nothing but mode notices announces nothing",
	noticesOnly.state.messages.length === 0,
	JSON.stringify(noticesOnly.state.messages.map((m) => m.content)),
);

// --- plan after a resume: the write tools must come back ---------------------
// The base tool set is captured from what is active at the first switch, and on a
// resume that is the transcript's restored loadout — oracle's, without edit/write.
// plan therefore has to list its own write tools; writeScope is what scopes them.
const planRun = await resume({ persisted: "oracle", active: ["read", "bash", "grep", "find", "ls"] });
planRun.shortcuts.get("ctrl+2").handler(planRun.ctx); // plan
await tick();
ok(
	"plan gets its write tools back after a resumed oracle session",
	planRun.state.active.includes("edit") && planRun.state.active.includes("write"),
	JSON.stringify(planRun.state.active),
);
ok(
	"plan still refuses a write outside its scope after a resume",
	(
		await planRun.handlers.get("tool_call")(
			{ toolName: "write", input: { path: "src/app.py", content: "x" }, toolCallId: "plan-1" },
			planRun.ctx,
		)
	)?.block === true,
);

// --- serialization: two switches inside one model swap -----------------------
// `applyModel` awaits `pi.setModel`, which resolves only when the provider swap
// lands. Two keystrokes inside that window must not interleave: the last switch has
// to own the tools, the persisted entry, the notice AND the model. Without the queue
// the *slower* swap wins the model while the later switch owns the mode.
//
// Asserted from the order of swap calls and settlements, not from wall-clock timing:
// a queued switch may not even CALL setModel until the previous swap settles, while an
// unqueued one calls both up front and settles them in reverse.
const raceConfig = path.join(repo.dir, "agent-modes.race.json");
writeFileSync(
	raceConfig,
	JSON.stringify({ modes: { oracle: { model: "slow-model" }, build: { model: "fast-model" } } }),
);
process.env.PI_AGENT_MODES_CONFIG = raceConfig;

const race = {
	flag: "",
	idle: true,
	active: ["read", "bash", "edit", "write", "grep", "find", "ls"],
	model: undefined,
	entries: [],
	messages: [],
	toasts: [],
	sessionEntries: [],
};
const raceLog = [];
const racePi = makePi(race);
racePi.pi.setModel = async (model) => {
	raceLog.push(`call:${model.id}`);
	await Promise.resolve(); // one microtask: enough for a second switch to slip in
	raceLog.push(`settle:${model.id}`);
	race.model = model.id;
	return true;
};
const raceExt = await import(`${path.join(HERE, "index.ts")}?race`);
raceExt.default(racePi.pi);
await racePi.handlers.get("session_start")({}, racePi.ctx);
racePi.shortcuts.get("ctrl+3").handler(racePi.ctx); // build — fired while oracle's swap is in flight
await new Promise((resolve) => setTimeout(resolve, 0));
ok(
	"the second switch waits for the first swap instead of interleaving",
	raceLog.join(" ") === "call:slow-model settle:slow-model call:fast-model settle:fast-model",
	raceLog.join(" "),
);
ok("the last switch owns the persisted mode", race.entries.at(-1)?.data?.mode === "build", JSON.stringify(race.entries.map((e) => e.data)));
ok("the last switch owns the model", race.model === "fast-model", String(race.model));
ok("the last switch owns the tool set", race.active.includes("edit") && race.active.includes("write"));
const raceNotice = race.messages.at(-1);
ok("one notice, describing the mode that is live", race.messages.length === 1, JSON.stringify(race.messages.map((m) => m.details)));
ok(
	"the notice names the model the session actually kept",
	String(raceNotice?.content ?? "").includes("`oracle` → `build`") &&
		String(raceNotice?.content ?? "").includes("Model: fast-model"),
	String(raceNotice?.content ?? ""),
);
delete process.env.PI_AGENT_MODES_CONFIG;

// Back to oracle: the drift audit below only applies in the safe (read-only) modes.
await shortcuts.get("ctrl+1").handler(ctx); // oracle
await tick();

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
rmSync(fakeHome, { recursive: true, force: true });

console.log(`\n${failures === 0 ? "all passed" : `${failures} failed`}`);
process.exit(failures === 0 ? 0 : 1);
