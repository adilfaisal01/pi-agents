/**
 * Agent discovery and configuration
 *
 * Vendored from pi's examples/extensions/subagent/agents.ts (MIT, Copyright (c)
 * earendil-works). Local changes are marked `LOCAL:` and are the reason this file
 * is not read from the pi install:
 *
 *   LOCAL 1  a third discovery root — this package's own `agents/` — so a package
 *            can ship agents and have them found. pi's own discovery only reads
 *            `~/.pi/agent/agents` and the nearest `.pi/agents`, both of which are
 *            outside a package.
 *   LOCAL 2  `write_scope` frontmatter, carried onto AgentConfig so the tool can
 *            verify after the fact what a child actually wrote.
 *   LOCAL 5  more than one package agents root: `pi.agents` in the package manifest,
 *            and the manifest one directory up. That is how a bundle (one npm package
 *            holding several extensions) ships an extension and its agents without
 *            copying the files into `agents/`.
 *
 * Keep upstream diffs small: adapt, do not rewrite.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { CONFIG_DIR_NAME, getAgentDir, parseFrontmatter } from "@earendil-works/pi-coding-agent";

export type AgentScope = "user" | "project" | "both";
/** LOCAL 2: `package` marks an agent shipped with this package. */
export type AgentSource = "user" | "project" | "package";

export interface AgentConfig {
	name: string;
	description: string;
	tools?: string[];
	model?: string;
	systemPrompt: string;
	source: AgentSource;
	filePath: string;
	/** LOCAL 2: repo-relative prefixes this agent may write. Undefined = unchecked. */
	writeScope?: string[];
}

export interface AgentDiscoveryResult {
	agents: AgentConfig[];
	projectAgentsDir: string | null;
}

/**
 * Raw agent frontmatter. Values are `unknown` because `parseFrontmatter` runs a
 * real YAML parser, so any scalar or collection can appear here.
 *
 * A type alias rather than an interface: `parseFrontmatter` constrains its
 * parameter to `Record<string, unknown>`, and only an alias picks up the
 * implicit index signature that satisfies it.
 */
type AgentFrontmatter = {
	name?: unknown;
	description?: unknown;
	tools?: unknown;
	model?: unknown;
	/** LOCAL 2: e.g. `write_scope: tests, conftest.py`. */
	write_scope?: unknown;
};

/**
 * Normalize a frontmatter `tools` value to a list of tool names.
 *
 * Both spellings are valid YAML and both are in use:
 *
 *     tools: read, bash        # string
 *     tools: [read, bash]      # array
 *
 * so accept either. Anything else (a number, a map, a nested list) yields no
 * tools rather than throwing: this runs inside agent discovery, where a single
 * bad file must not take down every other agent in the same directory.
 */
function parseToolList(value: unknown): string[] | undefined {
	const raw = Array.isArray(value) ? value : typeof value === "string" ? value.split(",") : [];
	const tools = raw
		.filter((t): t is string => typeof t === "string")
		.map((t) => t.trim())
		.filter(Boolean);
	return tools.length > 0 ? tools : undefined;
}

function loadAgentsFromDir(dir: string, source: AgentSource): AgentConfig[] {
	const agents: AgentConfig[] = [];

	if (!fs.existsSync(dir)) {
		return agents;
	}

	let entries: fs.Dirent[];
	try {
		entries = fs.readdirSync(dir, { withFileTypes: true });
	} catch {
		return agents;
	}

	for (const entry of entries) {
		if (!entry.name.endsWith(".md")) continue;
		if (!entry.isFile() && !entry.isSymbolicLink()) continue;

		const filePath = path.join(dir, entry.name);
		let content: string;
		try {
			content = fs.readFileSync(filePath, "utf-8");
		} catch {
			continue;
		}

		const { frontmatter, body } = parseFrontmatter<AgentFrontmatter>(content);

		if (typeof frontmatter.name !== "string" || typeof frontmatter.description !== "string") {
			continue;
		}

		agents.push({
			name: frontmatter.name,
			description: frontmatter.description,
			tools: parseToolList(frontmatter.tools),
			model: typeof frontmatter.model === "string" ? frontmatter.model : undefined,
			systemPrompt: body,
			source,
			filePath,
			writeScope: parseToolList(frontmatter.write_scope),
		});
	}

	return agents;
}

function isDirectory(p: string): boolean {
	try {
		return fs.statSync(p).isDirectory();
	} catch {
		return false;
	}
}

function findNearestProjectAgentsDir(cwd: string): string | null {
	let currentDir = cwd;
	while (true) {
		const candidate = path.join(currentDir, CONFIG_DIR_NAME, "agents");
		if (isDirectory(candidate)) return candidate;

		const parentDir = path.dirname(currentDir);
		if (parentDir === currentDir) return null;
		currentDir = parentDir;
	}
}

/**
 * LOCAL 5: the `pi.agents` entries of the package manifest at `root`, resolved against
 * it. Paths are package-relative, like every other `pi` manifest field. An unknown key
 * is ignored by pi itself, which reads only extensions/skills/prompts/themes from the
 * manifest; this key belongs to the tool that consumes it.
 */
export function declaredAgentDirs(root: string): string[] {
	try {
		const pkg = JSON.parse(fs.readFileSync(path.join(root, "package.json"), "utf-8")) as {
			pi?: { agents?: unknown };
		};
		const entries = pkg?.pi?.agents;
		if (!Array.isArray(entries)) return [];
		return entries.filter((entry): entry is string => typeof entry === "string" && entry.length > 0);
	} catch {
		return [];
	}
}

/**
 * LOCAL 1 + LOCAL 5: every directory this package ships agents in, in load order.
 *
 *  - `PI_SUBAGENT_PACKAGE_AGENTS` overrides the lot (the selftest uses it).
 *  - otherwise the module's own `agents/` directory, plus whatever the manifest at
 *    `<this dir>/package.json` and `<parent>/package.json` declares under `pi.agents`.
 *    The parent is read because a bundle installs this extension one directory down
 *    (`<bundle>/pi-subagent/agents.ts`) while the manifest lives at `<bundle>/`.
 *
 * Resolved from the module's own location, so it works wherever pi installed the
 * package — npm cache, git checkout, release dir.
 */
export function packageAgentsDirs(): string[] {
	const fromEnv = process.env.PI_SUBAGENT_PACKAGE_AGENTS;
	if (fromEnv) return [fromEnv];

	let own: string;
	try {
		own = path.dirname(fileURLToPath(import.meta.url));
	} catch {
		return [path.join(process.cwd(), "agents")];
	}

	const dirs: string[] = [];
	const add = (dir: string) => {
		if (!dirs.includes(dir)) dirs.push(dir);
	};
	const ownAgents = path.resolve(own, "agents");
	add(ownAgents);
	for (const root of [own, path.resolve(own, "..")]) {
		for (const rel of declaredAgentDirs(root)) add(path.resolve(root, rel));
	}
	return dirs;
}

/**
 * The first package agents directory. Kept because a consumer may resolve one dir; the
 * discovery path below uses every entry.
 */
export function packageAgentsDir(): string {
	return packageAgentsDirs()[0];
}

export function discoverAgents(cwd: string, scope: AgentScope): AgentDiscoveryResult {
	const userDir = path.join(getAgentDir(), "agents");
	const projectAgentsDir = findNearestProjectAgentsDir(cwd);

	const packageAgents = packageAgentsDirs().flatMap((dir) => loadAgentsFromDir(dir, "package"));
	const userAgents = scope === "project" ? [] : loadAgentsFromDir(userDir, "user");
	const projectAgents = scope === "user" || !projectAgentsDir ? [] : loadAgentsFromDir(projectAgentsDir, "project");

	const agentMap = new Map<string, AgentConfig>();

	// LOCAL 1: package agents are the floor — anything the user writes wins by name.
	for (const agent of packageAgents) agentMap.set(agent.name, agent);
	if (scope === "both") {
		for (const agent of userAgents) agentMap.set(agent.name, agent);
		for (const agent of projectAgents) agentMap.set(agent.name, agent);
	} else if (scope === "user") {
		for (const agent of userAgents) agentMap.set(agent.name, agent);
	} else {
		for (const agent of projectAgents) agentMap.set(agent.name, agent);
	}

	return { agents: Array.from(agentMap.values()), projectAgentsDir };
}

export function formatAgentList(agents: AgentConfig[], maxItems: number): { text: string; remaining: number } {
	if (agents.length === 0) return { text: "none", remaining: 0 };
	const listed = agents.slice(0, maxItems);
	const remaining = agents.length - listed.length;
	return {
		text: listed.map((a) => `${a.name} (${a.source}): ${a.description}`).join("; "),
		remaining,
	};
}
