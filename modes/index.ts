/**
 * Agent Modes — oracle / plan / build / yolo for pi.
 *
 * A per-mode agent switcher: each mode carries its own tool set, its own shell
 * policy, its own system-prompt contract, and (optionally) its own MODEL. This is
 * the piece pi core leaves out — pi has no named-agent concept, so modes here are
 * implemented as tool-schema + prompt + model state.
 *
 * Enforcement is structural where it can be:
 *   - oracle removes edit+write from the active tool set (dropTools), so they are
 *     absent from the prompt the model sees. The model cannot call a tool that isn't
 *     there, and keeps every read-only extension tool for context.
 *   - oracle/plan gate bash through a default-deny allowlist: reading commands plus
 *     an execute-class set (pytest/make test/lint/build tools), while auto-rewriters
 *     and generators (black, ruff --fix, --snapshot-update, scripts/gen_*.py) stay
 *     blocked.
 *   - around every allowed command in a safe mode, the tracked tree is snapshotted
 *     (porcelain status + digest of the pending diff) and any drift is appended to
 *     that command's result. Execution may produce evidence; it may not quietly
 *     leave a changed tracked file behind. Report-only: nothing is reverted.
 *   - a tool_call guard re-blocks writes in read-only modes as defense in depth, in
 *     case an injected instruction tries a tool that is no longer advertised.
 *
 * Bindings:
 *   alt+a       cycle modes (forward)  — NOT Tab; Tab must stay autocomplete-accept
 *   Ctrl+1..4   jump directly to oracle / plan / build / yolo
 *   Ctrl+Shift+M toggle oracle <-> build (one-key escape from a write mode)
 *
 * Commands / flags:
 *   /mode            pick a mode from a menu
 *   /mode <name>     switch directly
 *   --agent-mode <name>  start a session already in that mode
 *
 * State persists per session and is restored on resume. A session that has no
 * persisted mode of its own (every brand-new session) enters config.default.
 */

import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";
import { execFileSync } from "node:child_process";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import type { ExtensionAPI, ExtensionContext } from "@earendil-works/pi-coding-agent";

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

type BashPolicy = "none" | "safe" | "all";

interface ModeConfig {
	label: string;
	badge: string;
	color: string;
	model?: string;
	tools: string[];
	/** Removed from the resulting set even when keepExtensions kept them (e.g. writes). */
	dropTools?: string[];
	/**
	 * Repo-relative path prefixes this mode may write. `undefined` = unrestricted,
	 * `[]` = no writes at all. Matched as directories: "tests" covers "tests/x.py".
	 */
	writeScope?: string[];
	/** Repo-relative path prefixes this mode may never write (wins over writeScope). */
	writeDeny?: string[];
	bash: BashPolicy;
	keepExtensions?: boolean;
	promptFile?: string;
}

interface Config {
	cycleKey: string;
	/** Optional. Only needed when a model id is ambiguous across providers. */
	provider?: string;
	/** Mode entered when a session has neither --agent-mode nor a persisted mode. */
	default?: string;
	order: string[];
	modes: Record<string, ModeConfig>;
}

const DEFAULTS: Config = {
	cycleKey: "tab",
	default: "oracle",
	order: ["oracle", "plan", "build", "yolo"],
	modes: {
		oracle: {
			label: "oracle",
			badge: "🔍 oracle",
			color: "accent",
			tools: ["read", "grep", "find", "ls", "bash"],
			dropTools: ["edit", "write", "multiedit", "apply_patch"],
			writeScope: [],
			bash: "safe",
			keepExtensions: true,
		},
		plan: {
			label: "plan",
			badge: "📋 plan",
			color: "warning",
			tools: ["read", "grep", "find", "ls", "bash"],
			writeScope: ["docs", "ledger"],
			bash: "safe",
			keepExtensions: true,
		},
		build: {
			label: "build",
			badge: "🔨 build",
			color: "success",
			tools: ["read", "grep", "find", "ls", "edit", "write", "bash"],
			writeDeny: ["tests", "conftest.py", "pyproject.toml", "pytest.ini", "tox.ini", "setup.cfg", "gate/run-tests.sh"],
			bash: "all",
			keepExtensions: true,
		},
		yolo: {
			label: "yolo",
			badge: "⚡ yolo",
			color: "error",
			tools: ["read", "grep", "find", "ls", "edit", "write", "bash"],
			bash: "all",
			keepExtensions: true,
		},
	},
};

// ---------------------------------------------------------------------------
// Config + prompt loading
// ---------------------------------------------------------------------------

/**
 * The directory holding config.json and prompts/ — the one this module was loaded
 * from, wherever the package was installed. Previously this guessed at
 * ~/.pi/agent/extensions/agent-modes, which is wrong for a package installed from
 * npm or git (pi puts it under its own npm/release directory).
 */
function extensionDir(): string {
	const fromEnv = process.env.PI_AGENT_MODES_DIR;
	if (fromEnv) return fromEnv;
	try {
		const own = path.dirname(fileURLToPath(import.meta.url));
		if (fs.existsSync(path.join(own, "config.json"))) return own;
	} catch {
		/* bundled module: import.meta.url is not a file path */
	}
	const candidates = [
		path.join(os.homedir(), ".pi", "agent", "extensions", "agent-modes"),
		path.join(process.cwd(), ".pi", "extensions", "agent-modes"),
	];
	for (const c of candidates) {
		try {
			if (fs.existsSync(path.join(c, "config.json"))) return c;
		} catch {
			/* ignore */
		}
	}
	return candidates[0] as string;
}

function readConfigFile(file: string): Partial<Config> | undefined {
	try {
		return JSON.parse(fs.readFileSync(file, "utf8")) as Partial<Config>;
	} catch {
		return undefined;
	}
}

/**
 * Per-mode shallow merge: an override that sets one key keeps the rest of the
 * shipped profile for that mode. Without this, changing a model required editing
 * the file inside the package, which `pi update` overwrites.
 */
function mergeConfig(base: Config, over: Partial<Config> | undefined): Config {
	if (!over) return base;
	const modes: Record<string, ModeConfig> = { ...base.modes };
	for (const [name, patch] of Object.entries(over.modes ?? {})) {
		if (!patch || typeof patch !== "object") continue;
		const fallback: ModeConfig = {
			label: name,
			badge: name,
			color: "accent",
			tools: [],
			bash: "all",
		};
		modes[name] = { ...(base.modes[name] ?? fallback), ...patch };
	}
	return {
		cycleKey: over.cycleKey ?? base.cycleKey,
		provider: over.provider ?? base.provider,
		default: over.default ?? base.default,
		order: over.order ?? base.order,
		modes,
	};
}

/**
 * Override files, weakest first:
 *   1. the package's own config.json (shipped defaults)
 *   2. ~/.pi/agent/agent-modes.json          — this user, every project
 *   3. <cwd>/.pi/agent-modes.json            — this project, shared with the repo
 *   4. $PI_AGENT_MODES_CONFIG                — explicit, for CI and the selftest
 */
function configOverridePaths(): string[] {
	const envPath = process.env.PI_AGENT_MODES_CONFIG;
	const paths = [
		path.join(os.homedir(), ".pi", "agent", "agent-modes.json"),
		path.join(process.cwd(), ".pi", "agent-modes.json"),
	];
	if (envPath) paths.push(envPath);
	return paths;
}

function loadConfig(dir: string): Config {
	let config = mergeConfig(DEFAULTS, readConfigFile(path.join(dir, "config.json")));
	for (const file of configOverridePaths()) {
		if (path.resolve(file) === path.resolve(path.join(dir, "config.json"))) continue;
		config = mergeConfig(config, readConfigFile(file));
	}
	return config;
}

function loadPrompt(dir: string, mode: ModeConfig): string {
	if (!mode.promptFile) return "";
	try {
		return fs.readFileSync(path.join(dir, mode.promptFile), "utf8").trim();
	} catch {
		return "";
	}
}

// ---------------------------------------------------------------------------
// Bash policy — default-deny read-only allowlist
// ---------------------------------------------------------------------------

const DESTRUCTIVE_PATTERNS: RegExp[] = [
	/\brm\b/i,
	/\brmdir\b/i,
	/\bmv\b/i,
	/\bcp\b/i,
	/\bmkdir\b/i,
	/\btouch\b/i,
	/\bchmod\b/i,
	/\bchown\b/i,
	/\bchgrp\b/i,
	/\bln\b/i,
	/\btee\b/i,
	/\btruncate\b/i,
	/\bdd\b/i,
	/\bshred\b/i,
	/(^|[^<])>(?!>)/,
	/>>/,
	/\bnpm\s+(install|uninstall|update|ci|link|publish)/i,
	/\byarn\s+(add|remove|install|publish)/i,
	/\bpnpm\s+(add|remove|install|publish)/i,
	/\bpip\s+(install|uninstall)/i,
	/\bapt(-get)?\s+(install|remove|purge|update|upgrade)/i,
	/\bbrew\s+(install|uninstall|upgrade)/i,
	/\bgit\s+(add|commit|push|pull|merge|rebase|reset|checkout|branch\s+-[dD]|stash|cherry-pick|revert|tag|init|clone)/i,
	/\bsudo\b/i,
	/\bsu\b/i,
	/\bkill\b/i,
	/\bpkill\b/i,
	/\bkillall\b/i,
	/\breboot\b/i,
	/\bshutdown\b/i,
	/\bsystemctl\s+(start|stop|restart|enable|disable)/i,
	/\bservice\s+\S+\s+(start|stop|restart)/i,
	/\b(vim?|nano|emacs|code|subl)\b/i,
	// Auto-rewriters: they edit files by design, so they are never read-only.
	// NB: a leading \b cannot match before "--", hence the (^|\s) form.
	/(^|\s)--snapshot-(update|clean)\b/,
	/(^|\s)--inline-snapshot=(update|create)\b/,
	/^\s*black\b(?!\s+--check)/,
	/^\s*ruff\s+(format|check)\b.*\s--fix\b/,
	/^\s*ruff\s+format\b(?!\s+--(check|diff))/,
	/^\s*(npx\s+)?(prettier|eslint)\b.*\s--(write|fix)\b/,
	/^\s*gofmt\s+-w\b/,
	/^\s*cargo\s+fmt\b(?!\s+--check)/,
	// Generators write source by convention; run them in a writing mode instead.
	/\bgen_[a-z0-9_]+\.py\b/,
];

const SAFE_PATTERNS: RegExp[] = [
	/^\s*cat\b/,
	/^\s*head\b/,
	/^\s*tail\b/,
	/^\s*less\b/,
	/^\s*more\b/,
	/^\s*grep\b/,
	/^\s*find\b/,
	/^\s*ls\b/,
	/^\s*pwd\b/,
	/^\s*echo\b/,
	/^\s*printf\b/,
	/^\s*wc\b/,
	/^\s*sort\b/,
	/^\s*uniq\b/,
	/^\s*diff\b/,
	/^\s*file\b/,
	/^\s*stat\b/,
	/^\s*du\b/,
	/^\s*df\b/,
	/^\s*tree\b/,
	/^\s*which\b/,
	/^\s*whereis\b/,
	/^\s*type\b/,
	/^\s*env\b/,
	/^\s*printenv\b/,
	/^\s*uname\b/,
	/^\s*whoami\b/,
	/^\s*id\b/,
	/^\s*date\b/,
	/^\s*uptime\b/,
	/^\s*ps\b/,
	/^\s*free\b/,
	/^\s*git\s+(status|log|diff|show|branch|remote|config\s+--get)/i,
	/^\s*git\s+ls-/i,
	/^\s*npm\s+(list|ls|view|info|search|outdated|audit)/i,
	/^\s*yarn\s+(list|info|why|audit)/i,
	/^\s*node\s+--version/i,
	/^\s*python3?\s+--version/i,
	/^\s*curl\s/i,
	/^\s*jq\b/,
	/^\s*sed\s+-n/i,
	/^\s*awk\b/,
	/^\s*rg\b/,
	/^\s*fd\b/,
	/^\s*bat\b/,
	/^\s*eza\b/,
	// Execute-class: run the suite / linters / build to collect EVIDENCE. These
	// are allowed because they do not edit source by intent; the tracked-tree
	// audit below is what catches the ones that do it anyway.
	/^\s*pytest\b/,
	/^\s*python3?\s+-m\s+pytest\b/,
	/^\s*python3?\s+-m\s+(unittest|mypy|ruff|flake8)\b/,
	/^\s*python3?\s+-m\s+black\s+--check\b/,
	/^\s*make\s+(test|tests|test-[a-z0-9-]+|lint|check|test-zig|zig-build|zig-build-mpc)\b/,
	/^\s*ruff\s+(check|format\s+--(check|diff))\b/,
	/^\s*mypy\b/,
	/^\s*black\s+--check\b/,
	/^\s*(npx\s+(--no-install\s+)?)?tsc\s+(--noEmit|-p)\b/,
	/^\s*cargo\s+(test|check|build|clippy|metadata)\b/,
	/^\s*zig\s+build\b/,
	/^\s*go\s+(test|build|vet)\b/,
	/^\s*(npm|pnpm|yarn)\s+(test|run\s+(test|lint|check|typecheck))\b/,
];

function isSafeCommand(command: string): boolean {
	const destructive = DESTRUCTIVE_PATTERNS.some((p) => p.test(command));
	const safe = SAFE_PATTERNS.some((p) => p.test(command));
	return !destructive && safe;
}

// ---------------------------------------------------------------------------
// Tracked-tree audit for safe (read-only) modes
// ---------------------------------------------------------------------------
//
// An allowlist cannot make a mode read-only on its own: execution is allowed
// here because it produces evidence, and `pytest` is on the list — but test
// fixtures can regenerate shared paths, including tracked generated sources
// (e.g. generated sources checked into the tree under a codegen/ directory). The invariant
// that actually matters is therefore "no TRACKED file changes", and that is
// checkable: snapshot the porcelain status plus a digest of the pending diff
// before an allowed bash call, re-check after it, and report any drift into
// the tool result. Report-only by design — the human decides what to keep.

interface TreeSnapshot {
	root: string;
	status: string[];
	dirtyDigest: string;
}

function git(root: string, args: string[]): string | undefined {
	try {
		return execFileSync("git", args, {
			cwd: root,
			encoding: "utf8",
			stdio: ["ignore", "pipe", "ignore"],
			timeout: 5000,
			maxBuffer: 16 * 1024 * 1024,
		});
	} catch {
		return undefined;
	}
}

function digest(text: string): string {
	return createHash("sha256").update(text).digest("hex");
}

function snapshotTree(root: string): TreeSnapshot | undefined {
	if (git(root, ["rev-parse", "--is-inside-work-tree"])?.trim() !== "true") return undefined;
	const status = (git(root, ["status", "--porcelain=v1", "-uno"]) ?? "")
		.split("\n")
		.filter(Boolean);
	// A command that edits an ALREADY-dirty file leaves its status line
	// unchanged, so also digest the pending diff. Only needed when dirty.
	const dirtyDigest = status.length
		? digest(
				(git(root, ["diff", "--binary"]) ?? "") +
					(git(root, ["diff", "--cached", "--binary"]) ?? ""),
			)
		: "";
	return { root, status, dirtyDigest };
}

/** Human-readable drift report, or undefined when the tracked tree is unchanged. */
function describeDrift(pre: TreeSnapshot, post: TreeSnapshot, modeLabel: string): string | undefined {
	const was = new Set(pre.status);
	// Status lines that did not exist before the command.
	const fresh = post.status.filter((line) => !was.has(line));
	// Already-dirty files whose CONTENT moved (status line would be identical).
	const dirtyMoved = pre.dirtyDigest !== "" && pre.dirtyDigest !== post.dirtyDigest;
	if (fresh.length === 0 && !dirtyMoved) return undefined;

	const paths = fresh.map((line) => line.slice(3).trim()).filter(Boolean);
	// Already-dirty files are the only candidates when no new status line appeared.
	const suspects = dirtyMoved && paths.length === 0
		? pre.status.map((line) => line.slice(3).trim()).filter(Boolean)
		: paths;
	const shown = suspects.slice(0, 8).join(", ");
	const more = suspects.length > 8 ? ` (+${suspects.length - 8} more)` : "";
	const lines = [
		paths.length
			? `⚠ ${modeLabel} audit — this command changed TRACKED files: ${shown}${more}.`
			: `⚠ ${modeLabel} audit — this command changed the content of files that were already uncommitted: ${shown}${more}.`,
		`${modeLabel} is read-only toward tracked files. Nothing was reverted.`,
		"Check `git status` / `git diff`. If this output was not intended, discard it deliberately in a writing mode — do not build on it.",
	];
	return lines.join("\n");
}

// ---------------------------------------------------------------------------
// Extension
// ---------------------------------------------------------------------------

export default function agentModesExtension(pi: ExtensionAPI): void {
	const dir = extensionDir();
	let config = loadConfig(dir);

	let current: string | undefined;
	let baseTools: string[] | undefined;
	let prompts = new Map<string, string>();
	// bash toolCallId -> tracked-tree snapshot taken just before that command.
	const pendingAudits = new Map<string, { snapshot: TreeSnapshot; mode: string }>();

	function refreshPrompts(): void {
		prompts = new Map();
		for (const [name, mode] of Object.entries(config.modes)) {
			prompts.set(name, loadPrompt(dir, mode));
		}
	}
	refreshPrompts();

	function unique(names: string[]): string[] {
		return [...new Set(names)];
	}

	function toolsFor(name: string, activeAtCapture: string[]): string[] {
		const mode = config.modes[name];
		if (!mode) return activeAtCapture;
		const list =
			mode.keepExtensions === false
				? unique(mode.tools)
				: // union: keep whatever was already active (extensions included),
					// guarantee the mode's own tools
					unique([...(baseTools ?? activeAtCapture), ...mode.tools]);
		// dropTools is applied AFTER the union so keeping extensions cannot
		// smuggle back a tool the mode is meant to be without (edit/write).
		const drop = new Set(mode.dropTools ?? []);
		return drop.size ? list.filter((t) => !drop.has(t)) : list;
	}

	function updateStatus(ctx: ExtensionContext): void {
		if (!current) {
			ctx.ui.setStatus("agent-modes", undefined);
			return;
		}
		const mode = config.modes[current];
		const badge = mode?.badge ?? current;
		const color = mode?.color ?? "accent";
		ctx.ui.setStatus("agent-modes", ctx.ui.theme.fg(color as never, badge));
	}

	function notify(ctx: ExtensionContext, message: string, type?: "info" | "warning" | "error"): void {
		if (!ctx.hasUI) return;
		ctx.ui.notify(message, type ?? "info");
	}

	async function applyModel(name: string, ctx: ExtensionContext): Promise<string | undefined> {
		const mode = config.modes[name];
		// No model configured: leave whatever the session is using. This is the
		// shipped default — a package cannot know which providers a stranger has.
		if (!mode?.model) return undefined;

		const registry = ctx.modelRegistry as
			| {
					find?: (provider: string, id: string) => unknown;
					getAvailable?: () => { id?: string; provider?: string }[];
			  }
			| undefined;
		if (!registry) return undefined;

		const raw = mode.model;
		const slash = raw.indexOf("/");
		// "provider/id" is accepted, but only after the plain id has been tried:
		// some model ids contain a slash themselves.
		const attempts: { provider?: string; id: string }[] = [];
		if (config.provider) attempts.push({ provider: config.provider, id: raw });
		if (slash > 0) attempts.push({ provider: raw.slice(0, slash), id: raw.slice(slash + 1) });
		attempts.push({ id: raw });

		let model: { id?: string; provider?: string } | undefined;
		for (const attempt of attempts) {
			if (registry.find && (attempt.provider || !config.provider)) {
				const hit = registry.find(attempt.provider ?? "", attempt.id) as
					| { id?: string; provider?: string }
					| undefined;
				if (hit) {
					model = hit;
					break;
				}
			}
			const available = registry.getAvailable?.() ?? [];
			const scan = available.find(
				(m) => m.id === attempt.id && (!attempt.provider || m.provider === attempt.provider),
			);
			if (scan) {
				model = scan;
				break;
			}
		}

		if (!model) {
			notify(
				ctx,
				`agent-modes: model '${raw}' not found in this install — keeping the current model. ` +
					`Set it in ~/.pi/agent/agent-modes.json or <repo>/.pi/agent-modes.json.`,
				"warning",
			);
			return undefined;
		}

		const active = ctx.model as { id?: string } | undefined;
		if (active?.id === model.id) return model.id;

		// Await the swap so callers can report the model that ACTUALLY landed.
		// Previously this was fire-and-forget and setMode printed mode.model from
		// config, so a failed/no-op switch still announced the configured model
		// while the footer (live session state) showed the real one.
		try {
			const ok = (await pi.setModel(model as never)) as boolean;
			if (!ok) {
				notify(
					ctx,
					`agent-modes: no credentials for '${mode.model}' — model unchanged`,
					"warning",
				);
				return undefined;
			}
			return model.id;
		} catch (err: unknown) {
			notify(
				ctx,
				`agent-modes: model switch failed (${err instanceof Error ? err.message : String(err)})`,
				"warning",
			);
			return undefined;
		}
	}

	function persist(): void {
		pi.appendEntry("agent-modes", { mode: current });
	}

	async function setMode(
		name: string,
		ctx: ExtensionContext,
		opts?: { quiet?: boolean },
	): Promise<void> {
		const mode = config.modes[name];
		if (!mode) {
			ctx.ui.notify(
				`agent-modes: unknown mode '${name}' (have: ${Object.keys(config.modes).join(", ")})`,
				"error",
			);
			return;
		}

		// Capture the pre-mode tool set once, so build/yolo can restore it.
		if (baseTools === undefined) baseTools = pi.getActiveTools();

		current = name;
		pi.setActiveTools(toolsFor(name, pi.getActiveTools()));
		// Await the model swap BEFORE announcing, so the toast reports reality
		// rather than the configured intent. See applyModel.
		const applied = await applyModel(name, ctx);
		updateStatus(ctx);
		persist();

		if (!opts?.quiet) {
			const modelNote = applied ? ` · model ${applied}` : " · model unchanged";
			const bashNote = mode.bash === "none" ? " · shell off" : "";
			ctx.ui.notify(`Mode: ${mode.label}${modelNote}${bashNote}`, "info");
		}
	}

	function cycle(ctx: ExtensionContext): void {
		const order = config.order.filter((n) => config.modes[n]);
		if (order.length === 0) return;
		const idx = current ? order.indexOf(current) : -1;
		const next = order[(idx + 1) % order.length];
		if (next) setMode(next, ctx);
	}

	// --- flag ---------------------------------------------------------------
	pi.registerFlag("agent-mode", {
		description: "Start in a given agent mode (oracle|plan|build|yolo)",
		type: "string",
		default: "",
	});

	// --- commands -----------------------------------------------------------
	pi.registerCommand("mode", {
		description: "Show or switch the agent mode (oracle|plan|build|yolo)",
		handler: async (args, ctx) => {
			const requested = args?.trim().toLowerCase();
			if (requested) {
				setMode(requested, ctx);
				return;
			}
			const order = config.order.filter((n) => config.modes[n]);
			const labels = order.map((n) => {
				const m = config.modes[n];
				const model = m?.model ? ` — ${m.model}` : "";
				const marker = n === current ? " (current)" : "";
				return `${m?.label ?? n}${model}${marker}`;
			});
			const choice = await ctx.ui.select("Agent mode", labels);
			if (!choice) return;
			const picked = order[labels.indexOf(choice)];
			if (picked) setMode(picked, ctx);
		},
	});

	// --- shortcuts ----------------------------------------------------------
	// alt+a cycles (config.json cycleKey). Deliberately NOT "tab": extension
	// shortcuts are consulted BEFORE editor keybindings AND before autocomplete,
	// so binding "tab" silently steals the accept-completion key from
	// tui.input.tab (defaultKeys "tab", "Tab / autocomplete"). alt+a collides
	// with nothing in pi's default set and is not a reserved binding.
	pi.registerShortcut(config.cycleKey as never, {
		description: "Cycle agent mode",
		handler: async (ctx) => {
			cycle(ctx);
		},
	});

	pi.registerShortcut("ctrl+shift+m" as never, {
		description: "Toggle oracle / build",
		handler: async (ctx) => {
			setMode(current === "oracle" ? "build" : "oracle", ctx);
		},
	});

	const order = config.order.filter((n) => config.modes[n]);
	order.slice(0, 4).forEach((name, i) => {
		pi.registerShortcut(`ctrl+${i + 1}` as never, {
			description: `Switch to ${name} mode`,
			handler: async (ctx) => {
				setMode(name, ctx);
			},
		});
	});

	// --- enforcement --------------------------------------------------------
	const WRITE_TOOLS = new Set(["edit", "write", "multiedit", "apply_patch"]);

	/** Repo-relative, forward-slashed path for a tool's file argument; undefined if outside the tree. */
	function relPath(raw: string): string | undefined {
		if (!raw.trim()) return undefined;
		const abs = path.isAbsolute(raw) ? raw : path.resolve(process.cwd(), raw);
		const rel = path.relative(process.cwd(), abs);
		if (rel === "" || rel.startsWith("..")) return undefined;
		return rel.split(path.sep).join("/");
	}

	/** Directory-prefix match: "tests" covers "tests/x.py" and "tests" itself. */
	function inScope(rel: string, scope: string[]): boolean {
		return scope.some((entry) => {
			const p = entry.replace(/^\.\//, "").replace(/\/+$/, "");
			if (p === "" || p === "." || p === "*") return true;
			return rel === p || rel.startsWith(`${p}/`);
		});
	}

	pi.on("tool_call", async (event) => {
		if (!current) return;
		const mode = config.modes[current];
		if (!mode) return;

		if (WRITE_TOOLS.has(event.toolName)) {
			const raw = String((event.input as { path?: unknown }).path ?? "");
			const rel = relPath(raw);

			// writeScope: [] means the mode cannot write at all; a non-empty list is an
			// allowlist. Either way this is enforced here as well as by removing the
			// tool, because an injected instruction can still name a tool that is gone
			// from a different context.
			if (mode.writeScope !== undefined) {
				if (mode.writeScope.length === 0) {
					return {
						block: true,
						reason: `[${mode.label}] refused: write to '${raw || "(no path)"}' — this mode is read-only toward the repo. Switch modes to write.`,
					};
				}
				if (!rel || !inScope(rel, mode.writeScope)) {
					return {
						block: true,
						reason: `[${mode.label}] refused: write to '${rel ?? raw}' — this mode writes only ${mode.writeScope.join(", ")}.`,
					};
				}
			}

			// writeDeny wins over scope and over keepExtensions: the frozen test surface
			// is not a place a build lane edits, whatever else it may touch.
			if (mode.writeDeny?.length && rel && inScope(rel, mode.writeDeny)) {
				return {
					block: true,
					reason:
						`[${mode.label}] refused: write to '${rel}' — the frozen test surface is locked ` +
						`(${mode.writeDeny.join(", ")}). A test changes only by a recorded amendment; a build lane never edits one.`,
				};
			}
		}

		if (event.toolName !== "bash") return;
		if (mode.bash === "all") return;

		if (mode.bash === "none") {
			return {
				block: true,
				reason: `[${mode.label}] shell access is disabled in this mode. Switch modes (Tab) for shell access.`,
			};
		}

		const command = String((event.input as { command?: unknown }).command ?? "");
		if (!isSafeCommand(command)) {
			return {
				block: true,
				reason: `[${mode.label}] command blocked — not on the read-only allowlist. Switch modes (Tab) to run it.\nCommand: ${command}`,
			};
		}

		// Allowed. Remember the tracked tree so tool_result can report drift the
		// command caused (report-only; nothing is reverted behind the user's back).
		if (event.toolCallId) {
			const snapshot = snapshotTree(process.cwd());
			if (snapshot) {
				if (pendingAudits.size >= 32) pendingAudits.clear();
				pendingAudits.set(event.toolCallId, { snapshot, mode: mode.label });
			}
		}
	});

	// --- tracked-tree audit (safe modes) ------------------------------------
	// Execution is what makes oracle useful, but it must not leave a changed
	// tracked file behind unnoticed. Append the drift to the command's own
	// result so the agent sees it before it reasons on top of it.
	pi.on("tool_result", async (event, ctx) => {
		const pending = pendingAudits.get(event.toolCallId);
		if (!pending) return;
		pendingAudits.delete(event.toolCallId);
		if (event.toolName !== "bash") return;

		const post = snapshotTree(pending.snapshot.root);
		if (!post) return;
		const drift = describeDrift(pending.snapshot, post, pending.mode);
		if (!drift) return;

		// The model sees the appended text; the human gets a toast, because a
		// tool result is easy to skim past and this is the one event that breaks
		// the read-only contract.
		if (ctx.hasUI) ctx.ui.notify(drift.split("\n")[0] as string, "warning");

		return { content: [...event.content, { type: "text" as const, text: drift }] };
	});

	// --- prompt contract ----------------------------------------------------
	pi.on("before_agent_start", async (event) => {
		if (!current) return;
		const mode = config.modes[current];
		if (!mode) return;

		const prompt = prompts.get(current) ?? "";
		if (!prompt) return;

		const shell =
			mode.bash === "none"
				? "unavailable"
				: mode.bash === "safe"
					? "restricted to a read-only allowlist"
					: "unrestricted";

		return {
			systemPrompt:
				`${event.systemPrompt}\n\n---\n${prompt}\n\n` +
				`Active tools right now: ${pi.getActiveTools().join(", ")}. ` +
				`Shell: ${shell}.`,
		};
	});

	// --- lifecycle ----------------------------------------------------------
	pi.on("session_start", async (_event, ctx) => {
		config = loadConfig(dir);
		refreshPrompts();
		baseTools = undefined;

		const entries = ctx.sessionManager.getEntries();
		const last = entries
			.filter(
				(e: { type: string; customType?: string }) =>
					e.type === "custom" && e.customType === "agent-modes",
			)
			.pop() as { data?: { mode?: string } } | undefined;

		const flag = pi.getFlag("agent-mode");
		const requested =
			typeof flag === "string" && flag.trim() ? flag.trim().toLowerCase() : undefined;

		// Fallback chain: --agent-mode flag, then the mode persisted for THIS
		// session, then config.default. An unknown name in any slot falls through
		// to the next instead of leaving the session mode-less.
		const persisted = last?.data?.mode;
		const target =
			(requested && config.modes[requested] ? requested : undefined) ??
			(persisted && config.modes[persisted] ? persisted : undefined) ??
			(config.default && config.modes[config.default] ? config.default : undefined);

		if (target) {
			setMode(target, ctx, { quiet: !requested });
		} else {
			updateStatus(ctx);
		}
	});
}
