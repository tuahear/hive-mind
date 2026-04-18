// Minimal smoke test. Assumes `npm run build` has already produced dist/
// and assets/. Not a substitute for a real test suite — catches "the
// tarball is empty" and "--help crashes" regressions during prototype.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const cliDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const isWin = process.platform === "win32";

function assert(cond, msg) {
  if (!cond) {
    console.error(`SMOKE FAIL: ${msg}`);
    process.exit(1);
  }
  console.log(`SMOKE OK: ${msg}`);
}

function node(args, opts = {}) {
  return spawnSync(process.execPath, args, {
    cwd: cliDir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], ...opts,
  });
}

function npm(args, opts = {}) {
  return spawnSync(isWin ? "npm.cmd" : "npm", args, {
    cwd: cliDir, encoding: "utf8", stdio: ["ignore", "pipe", "pipe"], shell: isWin, ...opts,
  });
}

// 1. Build artifacts present.
assert(existsSync(resolve(cliDir, "dist", "cli.js")), "dist/cli.js present (run `npm run build` first)");
assert(existsSync(resolve(cliDir, "assets", "setup.sh")), "assets/setup.sh bundled");
assert(existsSync(resolve(cliDir, "assets", "core", "hub", "sync.sh")), "assets/core/hub/sync.sh bundled");

// 2. --version responds.
const ver = node(["dist/cli.js", "--version"]);
assert(ver.status === 0 && ver.stdout.trim().length > 0, `--version (got='${ver.stdout.trim()}' err='${ver.stderr}')`);

// 3. --help lists every subcommand.
const help = node(["dist/cli.js", "--help"]);
assert(help.status === 0, `--help status (stderr='${help.stderr}')`);
for (const cmd of ["init", "attach", "detach", "status", "sync", "pull", "doctor", "version"]) {
  assert(help.stdout.includes(cmd), `--help lists '${cmd}'`);
}

// 4. doctor runs against a non-existent hub without crashing.
const doc = node(["dist/cli.js", "doctor", "--json"], {
  env: { ...process.env, HIVE_MIND_HUB_DIR: resolve(cliDir, ".smoke-hub") },
});
assert(doc.stdout.includes('"checks"'), `doctor --json emits JSON (stderr='${doc.stderr}')`);

// 4b. `hivemind init --yes` without a memory repo + no existing hub fails
// fast rather than hanging on setup.sh's interactive read.
const smokeHub = resolve(cliDir, ".smoke-hub-failfast");
const failfast = node(["dist/cli.js", "init", "--yes", "--adapter", "claude-code"], {
  env: { ...process.env, HIVE_MIND_HUB_DIR: smokeHub, MEMORY_REPO: "" },
});
assert(failfast.status !== 0, `init --yes without memory-repo exits non-zero (got status=${failfast.status})`);
assert(
  (failfast.stderr + failfast.stdout).includes("--memory-repo"),
  `init --yes without memory-repo mentions --memory-repo in error (stderr='${failfast.stderr}')`
);

// 4c. `status` on a freshly-init-but-never-pushed-looking git repo reports
// "no upstream" instead of silently saying 0 unpushed commits.
{
  const { rmSync, mkdirSync } = await import("node:fs");
  const fakeHub = resolve(cliDir, ".smoke-hub-upstream");
  rmSync(fakeHub, { recursive: true, force: true });
  mkdirSync(fakeHub, { recursive: true });
  const git = (args) => spawnSync("git", args, { cwd: fakeHub, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" });
  const gi = git(["init", "-q"]);
  assert(gi.status === 0, `git init (stderr='${gi.stderr}')`);
  // CI boxes often have no global identity; set repo-local so `git commit`
  // doesn't fail with "Please tell me who you are".
  assert(git(["config", "user.email", "smoke@example.invalid"]).status === 0, "git config user.email");
  assert(git(["config", "user.name", "Smoke Test"]).status === 0, "git config user.name");
  const gc = git(["commit", "--allow-empty", "-m", "seed", "-q"]);
  assert(gc.status === 0, `git commit (stderr='${gc.stderr}')`);
  const s = node(["dist/cli.js", "status", "--json"], { env: { ...process.env, HIVE_MIND_HUB_DIR: fakeHub } });
  assert(s.stdout.includes('"unpushedCommits": null'), `status reports null for unpushed when no upstream (got stdout='${s.stdout}')`);
}

// 4c2. status on a hub that doesn't exist reports unpushedCommits:null,
// not 0 — "0" would read like "everything in sync" pre-install.
{
  const missingHub = resolve(cliDir, ".smoke-hub-missing");
  const { rmSync } = await import("node:fs");
  rmSync(missingHub, { recursive: true, force: true });
  const s = node(["dist/cli.js", "status", "--json"], { env: { ...process.env, HIVE_MIND_HUB_DIR: missingHub } });
  assert(s.stdout.includes('"unpushedCommits": null'), `status reports null unpushed when hub missing (got='${s.stdout}')`);
}

// 4c3. readAttachedAdapters filters `#` comment lines so they don't show
// up as fake adapters in status/version/doctor.
{
  const { mkdirSync, writeFileSync, rmSync } = await import("node:fs");
  const hub = resolve(cliDir, ".smoke-hub-comments");
  rmSync(hub, { recursive: true, force: true });
  mkdirSync(resolve(hub, ".install-state"), { recursive: true });
  writeFileSync(resolve(hub, ".install-state", "attached-adapters"), "# this is a comment\nclaude-code\n\n  # indented\ncodex\n");
  const s = node(["dist/cli.js", "version", "--json"], { env: { ...process.env, HIVE_MIND_HUB_DIR: hub } });
  const parsed = JSON.parse(s.stdout);
  assert(
    JSON.stringify(parsed.attached) === JSON.stringify(["claude-code", "codex"]),
    `attached-adapters parser skips # comments (got=${JSON.stringify(parsed.attached)})`
  );
}

// 4d. adapter name validation — reject traversal and whitespace.
for (const bad of ["codex/", "../evil", "bad name", ""]) {
  const r = node(["dist/cli.js", "attach", bad]);
  assert(r.status !== 0, `attach rejects '${bad}' (status=${r.status})`);
}
const okAttach = node(["dist/cli.js", "attach", "codex"], { env: { ...process.env, HIVE_MIND_HUB_DIR: resolve(cliDir, ".no-such-hub") } });
// Valid name, but no hub → must fail with the 'hub not initialized' message, not the validator.
assert(okAttach.status === 1 && okAttach.stderr.includes("hub not initialized"), `attach codex with no hub hits hub-init error, not validator (status=${okAttach.status}, stderr='${okAttach.stderr}')`);

// 5. npm pack stays under 2 MB (CLI spec cap).
// --ignore-scripts so the prepack build doesn't mix its stdout into the
// JSON response we're about to parse.
const pack = npm(["pack", "--dry-run", "--json", "--ignore-scripts"]);
try {
  const info = JSON.parse(pack.stdout)[0];
  assert(info.size < 2 * 1024 * 1024, `tarball under 2 MB (got ${(info.size / 1024).toFixed(1)} KB)`);
} catch (e) {
  assert(false, `parse npm pack --json: ${e} stderr=${pack.stderr}`);
}

console.log("\nall smoke checks passed");
