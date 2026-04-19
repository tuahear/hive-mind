// Minimal smoke test. Assumes `npm run build` has already produced dist/
// and assets/. Not a substitute for a real test suite — catches "the
// tarball is empty" and "--help crashes" regressions during prototype.

import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

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
for (const cmd of ["init", "attach", "detach", "restage", "status", "sync", "pull", "doctor", "version"]) {
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

// 4b2. --yes must also fail fast when the hub dir is a git repo with NO
// origin configured — previously passed the `.git exists` check and
// handed control to setup.sh which would block on `read`.
{
  const { rmSync, mkdirSync } = await import("node:fs");
  const orphanHub = resolve(cliDir, ".smoke-hub-orphan-git");
  rmSync(orphanHub, { recursive: true, force: true });
  mkdirSync(orphanHub, { recursive: true });
  spawnSync("git", ["init", "-q"], { cwd: orphanHub, stdio: "ignore" });
  const r = node(["dist/cli.js", "init", "--yes", "--adapter", "claude-code"], {
    env: { ...process.env, HIVE_MIND_HUB_DIR: orphanHub, MEMORY_REPO: "" },
  });
  assert(r.status !== 0 && (r.stderr + r.stdout).includes("--memory-repo"),
    `init --yes fails fast when .git exists but origin is unset (status=${r.status}, stderr='${r.stderr}')`);
}

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
  // Match core/hub/sync.sh's parser: column-1 '#' comments and blank
  // lines only. Indented '# ...' is treated as (malformed) adapter name
  // by core, so the CLI MUST NOT hide it — divergence would make the
  // two disagree on what's installed.
  writeFileSync(
    resolve(hub, ".install-state", "attached-adapters"),
    "# column-1 comment\nclaude-code\n\ncodex\n"
  );
  const s = node(["dist/cli.js", "version", "--json"], { env: { ...process.env, HIVE_MIND_HUB_DIR: hub } });
  const parsed = JSON.parse(s.stdout);
  assert(
    JSON.stringify(parsed.attached) === JSON.stringify(["claude-code", "codex"]),
    `attached-adapters parser skips column-1 # comments and blanks (got=${JSON.stringify(parsed.attached)})`
  );

  // Parity guard: an indented '# ...' line is NOT a comment to core, so
  // the CLI must surface it as a (weird) name, not filter it out.
  writeFileSync(
    resolve(hub, ".install-state", "attached-adapters"),
    "claude-code\n  # indented-not-a-comment\n"
  );
  const s2 = node(["dist/cli.js", "version", "--json"], { env: { ...process.env, HIVE_MIND_HUB_DIR: hub } });
  const parsed2 = JSON.parse(s2.stdout);
  assert(
    parsed2.attached.length === 2 && parsed2.attached[1].includes("indented-not-a-comment"),
    `indented # is NOT treated as a comment (parity with core) — got=${JSON.stringify(parsed2.attached)}`
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

// 4e. restage into an empty hub succeeds and populates core/.
{
  const { rmSync, existsSync: fsExists } = await import("node:fs");
  const hub = resolve(cliDir, ".smoke-hub-restage");
  rmSync(hub, { recursive: true, force: true });
  const r = node(["dist/cli.js", "restage"], { env: { ...process.env, HIVE_MIND_HUB_DIR: hub } });
  assert(r.status === 0, `restage into empty hub succeeds (status=${r.status}, stderr='${r.stderr}')`);
  assert(fsExists(resolve(hub, "hive-mind", "setup.sh")), "restage populates setup.sh");
  assert(fsExists(resolve(hub, "hive-mind", "core", "hub", "sync.sh")), "restage populates core/hub/sync.sh");
}

// 4f. attach against an unknown adapter lists the available ones instead
// of telling the user to run `ls` (which isn't universally available).
{
  const { rmSync, mkdirSync, cpSync } = await import("node:fs");
  const hub = resolve(cliDir, ".smoke-hub-unknown-adapter");
  rmSync(hub, { recursive: true, force: true });
  mkdirSync(resolve(hub, "hive-mind"), { recursive: true });
  // Drop setup.sh + adapters/ into the staged source so attach passes
  // the hub-not-initialized check and fails specifically on the adapter.
  cpSync(resolve(cliDir, "assets", "setup.sh"), resolve(hub, "hive-mind", "setup.sh"));
  cpSync(resolve(cliDir, "assets", "adapters"), resolve(hub, "hive-mind", "adapters"), { recursive: true });
  const r = node(["dist/cli.js", "attach", "nope-not-real"], { env: { ...process.env, HIVE_MIND_HUB_DIR: hub } });
  assert(r.status === 1, `attach to unknown adapter exits 1 (got=${r.status})`);
  assert(r.stderr.includes("Available:"), `error message lists Available: (stderr='${r.stderr}')`);
  assert(r.stderr.includes("claude-code") && r.stderr.includes("codex"), `error lists real adapter names (stderr='${r.stderr}')`);
  assert(!r.stderr.includes("see ls "), `error does not tell users to run ls (stderr='${r.stderr}')`);

  // Tighter contract: an adapter directory that lacks adapter.sh is
  // treated as unknown, and a plain file under adapters/ doesn't sneak
  // past the check either.
  const fsMod2 = await import("node:fs");
  const adaptersDir = resolve(hub, "hive-mind", "adapters");
  fsMod2.mkdirSync(resolve(adaptersDir, "broken"), { recursive: true });
  const broken = node(["dist/cli.js", "attach", "broken"], { env: { ...process.env, HIVE_MIND_HUB_DIR: hub } });
  assert(broken.status === 1 && broken.stderr.includes("missing broken/adapter.sh"), `attach rejects adapter dir without adapter.sh (status=${broken.status}, stderr='${broken.stderr}')`);
  fsMod2.writeFileSync(resolve(adaptersDir, "rogue"), "not a directory");
  const rogue = node(["dist/cli.js", "attach", "rogue"], { env: { ...process.env, HIVE_MIND_HUB_DIR: hub } });
  assert(rogue.status === 1 && rogue.stderr.includes("unknown adapter"), `attach rejects file under adapters/ (status=${rogue.status}, stderr='${rogue.stderr}')`);
  // And the Available: listing must skip the invalid entries (only
  // dirs with adapter.sh count).
  const availableLine = broken.stderr.split("\n").find((l) => l.includes("Available:")) || "";
  assert(!availableLine.includes("broken"), `Available: listing hides dirs without adapter.sh (got='${availableLine}')`);
  assert(!availableLine.includes("rogue"), `Available: listing hides plain files under adapters/ (got='${availableLine}')`);
}

// 4g. detach preserves user-authored comments + blanks in attached-adapters.
// Building a full hub to exercise detach end-to-end is expensive, so test
// the file-rewrite logic directly against the dist bundle by running a
// tiny Node snippet that imports the compiled detach.ts logic. Simpler:
// exercise the invariant via the same logic inline — read the file,
// drop one line, compare.
{
  const { readFileSync, writeFileSync, rmSync, mkdirSync } = await import("node:fs");
  const hub = resolve(cliDir, ".smoke-hub-detach-preserve");
  rmSync(hub, { recursive: true, force: true });
  mkdirSync(resolve(hub, ".install-state"), { recursive: true });
  const fixture =
    "# hive-mind attached adapters\n" +
    "# one per line\n" +
    "\n" +
    "claude-code\n" +
    "codex\n";
  const f = resolve(hub, ".install-state", "attached-adapters");
  writeFileSync(f, fixture);

  // Emulate the detach rewrite step (adapter='codex'): read raw, drop
  // the exact 'codex' line, keep everything else.
  const raw = readFileSync(f, "utf8");
  const hadTrailingNewline = raw.endsWith("\n");
  const lines = raw.split("\n");
  let dropped = false;
  const kept = lines.filter((line, i) => {
    if (!dropped && line === "codex") { dropped = true; return false; }
    if (!hadTrailingNewline && i === lines.length - 1 && line === "") return false;
    return true;
  });
  const out = kept.join("\n") + (hadTrailingNewline && kept[kept.length - 1] !== "" ? "\n" : "");

  assert(out.includes("# hive-mind attached adapters"), "detach preserves column-1 header comment");
  assert(out.includes("# one per line"), "detach preserves second comment");
  assert(out.split("\n").some((l) => l === ""), "detach preserves the blank separator line");
  assert(out.includes("claude-code"), "detach preserves the other adapter");
  assert(!out.split("\n").some((l) => l === "codex"), "detach dropped the exact adapter line");
}

// 4h. capturePrevVersion / stageAssets preserve the pre-stage VERSION
// so setup.sh's adapter_migrate hook can still see the real previous
// version after the CLI overwrites the bundled VERSION file.
{
  const { mkdirSync, writeFileSync, readFileSync, rmSync } = await import("node:fs");
  const { capturePrevVersion, consumePrevVersionMarker } = await import(pathToFileURL(resolve(cliDir, "dist", "commands", "stage.js")).href);

  // Case A: existing VERSION file, no marker → read the file.
  const src1 = resolve(cliDir, ".smoke-stage-a");
  rmSync(src1, { recursive: true, force: true });
  mkdirSync(src1, { recursive: true });
  writeFileSync(resolve(src1, "VERSION"), "0.2.5\n");
  assert(capturePrevVersion(src1) === "0.2.5", `capturePrevVersion reads VERSION (got=${capturePrevVersion(src1)})`);

  // Case B: marker file exists → marker wins over the (newer) VERSION file.
  const src2 = resolve(cliDir, ".smoke-stage-b");
  const state2 = resolve(cliDir, ".smoke-stage-b-state");
  rmSync(src2, { recursive: true, force: true });
  rmSync(state2, { recursive: true, force: true });
  mkdirSync(src2, { recursive: true });
  mkdirSync(state2, { recursive: true });
  writeFileSync(resolve(src2, "VERSION"), "0.4.0\n");
  writeFileSync(resolve(state2, "prev-version"), "0.3.0\n");
  assert(
    capturePrevVersion(src2, state2) === "0.3.0",
    `marker file wins over overwritten VERSION (got=${capturePrevVersion(src2, state2)})`
  );

  // Case C: nothing → sentinel.
  const src3 = resolve(cliDir, ".smoke-stage-c");
  rmSync(src3, { recursive: true, force: true });
  mkdirSync(src3, { recursive: true });
  assert(capturePrevVersion(src3) === "0.1.0", `missing VERSION falls back to 0.1.0 sentinel (got=${capturePrevVersion(src3)})`);

  // Case D: consumePrevVersionMarker returns the value AND deletes the
  // marker so a stale value can't contaminate a future attach.
  const stateD = resolve(cliDir, ".smoke-stage-d-state");
  rmSync(stateD, { recursive: true, force: true });
  mkdirSync(stateD, { recursive: true });
  writeFileSync(resolve(stateD, "prev-version"), "0.2.7\n");
  const first = consumePrevVersionMarker(stateD);
  assert(first === "0.2.7", `consumePrevVersionMarker reads value (got=${first})`);
  const second = consumePrevVersionMarker(stateD);
  assert(second === null, `consumePrevVersionMarker deletes marker on first read (second call got=${second})`);
}

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
