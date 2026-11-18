#!/usr/bin/env node
// check-manifest.mjs — is this repository publishable as the npm package it claims to be?
//
//   node scripts/check-manifest.mjs
//
// Checks the manifest against what pi and npm actually read: every `pi` resource path
// exists, every `bin` target is executable, the host packages are peers and not
// dependencies, and the tarball npm would publish contains each resource. No network, no
// model calls. Exits non-zero on the first class of failure that would break an install.

import { execFileSync } from "node:child_process";
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const HOST_PACKAGES = [
	"@earendil-works/pi-agent-core",
	"@earendil-works/pi-ai",
	"@earendil-works/pi-coding-agent",
	"@earendil-works/pi-tui",
	"typebox",
];

let failed = 0;
const ok = (name, cond, detail = "") => {
	if (cond) {
		console.log(`  ok    ${name}`);
	} else {
		failed += 1;
		console.log(`  FAIL  ${name}${detail ? ` — ${detail}` : ""}`);
	}
};

const pkg = JSON.parse(readFileSync(path.join(ROOT, "package.json"), "utf-8"));
const pi = pkg.pi ?? {};

ok("name is scoped or plain", typeof pkg.name === "string" && pkg.name.length > 0, pkg.name);
ok("version is semver", /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/.test(pkg.version ?? ""), pkg.version);
ok('license is declared', typeof pkg.license === "string" && pkg.license.length > 0, pkg.license);
ok("keywords carry pi-package (gallery discovery)", (pkg.keywords ?? []).includes("pi-package"));
ok("engines.node matches pi's own floor", typeof pkg.engines?.node === "string", pkg.engines?.node);

const deps = Object.keys(pkg.dependencies ?? {});
const hostedAsDependency = HOST_PACKAGES.filter((name) => deps.includes(name));
ok(
	"host packages are not dependencies",
	hostedAsDependency.length === 0,
	`${hostedAsDependency.join(", ")} — pi provides these; a copy breaks its module mapping`,
);
const peers = Object.keys(pkg.peerDependencies ?? {});
const unpeered = HOST_PACKAGES.filter((name) => !peers.includes(name));
ok("host packages are peers", unpeered.length === 0, unpeered.join(", "));

// Every resource the manifest declares must exist, or pi silently loads nothing.
for (const type of ["extensions", "skills", "prompts"]) {
	const entries = pi[type] ?? [];
	ok(`pi.${type} is a non-empty list`, Array.isArray(entries) && entries.length > 0);
	for (const rel of entries) {
		ok(`pi.${type} → ${rel}`, existsSync(path.resolve(ROOT, rel)), path.resolve(ROOT, rel));
	}
}

// `pi.agents` is ours, not pi's: the subagent extension reads it (declaredAgentDirs).
const agentDirs = pi.agents ?? [];
ok("pi.agents is a non-empty list", agentDirs.length > 0);
for (const rel of agentDirs) {
	const dir = path.resolve(ROOT, rel);
	let agents = 0;
	try {
		agents = readdirSync(dir).filter((f) => f.endsWith(".md")).length;
	} catch {
		agents = 0;
	}
	ok(`pi.agents → ${rel} carries at least one agent`, agents > 0, `${agents} file(s) in ${dir}`);
}

for (const [name, rel] of Object.entries(pkg.bin ?? {})) {
	const file = path.resolve(ROOT, rel);
	const executable = existsSync(file) && (statSync(file).mode & 0o111) !== 0;
	ok(`bin ${name} → ${rel} exists and is executable`, executable, file);
}

// What npm would actually ship. `files` is an allow-list, so a resource outside it is a
// path that exists in the repo and not in the installed package.
let packed = [];
try {
	const out = execFileSync("npm", ["pack", "--dry-run", "--json"], { cwd: ROOT, encoding: "utf-8" });
	packed = JSON.parse(out)[0].files.map((f) => f.path);
	ok("npm pack produced a file list", packed.length > 0, `${packed.length} file(s)`);
} catch (error) {
	failed += 1;
	console.log(`  FAIL  npm pack --dry-run did not run — ${error instanceof Error ? error.message : error}`);
}

const covered = (wanted) => {
	const rel = wanted.replace(/^\.\//, "").replace(/\/$/, "");
	return packed.some((entry) => entry === rel || entry.startsWith(`${rel}/`));
};
for (const type of ["skills", "prompts", "agents"]) {
	for (const rel of pi[type] ?? []) ok(`packed: pi.${type} ${rel}`, covered(rel));
}
for (const rel of pi.extensions ?? []) ok(`packed: extension ${rel}`, covered(rel));
for (const rel of Object.values(pkg.bin ?? {})) ok(`packed: bin ${rel}`, covered(rel));

ok("packed: README.md", packed.includes("README.md"));
ok("packed: LICENSE", packed.includes("LICENSE"));
ok("packed: CHANGELOG.md", packed.includes("CHANGELOG.md"));
for (const forbidden of [".git/", "node_modules/", "review-work/", "__pycache__/", ".pytest_cache/"]) {
	ok(`packed: no ${forbidden}`, !packed.some((entry) => entry.includes(forbidden)));
}
for (const pattern of [/\.pyc$/, /\.tgz$/, /(^|\/)\.DS_Store$/]) {
	ok(`packed: no ${pattern}`, !packed.some((entry) => pattern.test(entry)));
}

if (failed > 0) {
	console.log(`\n${failed} manifest check(s) failed`);
	process.exit(1);
}
console.log("\nmanifest is publishable");
