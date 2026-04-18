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
