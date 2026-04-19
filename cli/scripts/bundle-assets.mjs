// Copies the bash core + adapters + Go hook source from the repo root
// into cli/assets/ so they ship inside the published npm tarball. This
// is what removes the "clone the whole repo to install" pain — the CLI
// carries its own copy of the pieces it needs.
//
// Also cross-compiles the hivemind-hook launcher for every supported
// OS/arch and drops the binaries under cli/assets/prebuilt/. setup.sh
// prefers a matching prebuilt over a source build so users don't need
// the Go toolchain at install time. Binaries are build output, never
// committed (cli/assets/ is gitignored).

import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const cliRoot = resolve(here, "..");
const repoRoot = resolve(cliRoot, "..");
const out = resolve(cliRoot, "assets");

// `cmd` + `go.mod` are required too: the shipped claude-code / codex
// adapters always build the native hivemind-hook launcher during
// setup.sh, which needs the Go sources. A tarball missing any of these
// is broken — hard-fail at pack time rather than at user-install time.
const required = ["core", "adapters", "cmd", "setup.sh", "VERSION", "go.mod"];

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

for (const item of required) {
  const src = resolve(repoRoot, item);
  if (!existsSync(src)) {
    console.error(`[bundle-assets] required asset missing from repo root: ${item}`);
    process.exit(1);
  }
  const dst = resolve(out, item);
  mkdirSync(dirname(dst), { recursive: true });
  cpSync(src, dst, { recursive: true });
}

// Cross-compile the hivemind-hook launcher for every supported
// OS/arch. Skipped if Go isn't on PATH so local dev without Go still
// works (setup.sh falls back to source-build at install time); the
// release pipeline must have Go or binaries will be absent.
const prebuiltDir = resolve(out, "prebuilt");
mkdirSync(prebuiltDir, { recursive: true });
const HOOK_TARGETS = [
  { goos: "darwin", goarch: "arm64", name: "hivemind-hook-darwin-arm64" },
  { goos: "darwin", goarch: "amd64", name: "hivemind-hook-darwin-amd64" },
  { goos: "linux", goarch: "amd64", name: "hivemind-hook-linux-amd64" },
  { goos: "linux", goarch: "arm64", name: "hivemind-hook-linux-arm64" },
  { goos: "windows", goarch: "amd64", name: "hivemind-hook-windows-amd64.exe" },
];
const goAvailable = spawnSync("go", ["version"], { stdio: ["ignore", "pipe", "pipe"] }).status === 0;
const builtTargets = [];
if (!goAvailable) {
  const force = process.env.HIVE_MIND_REQUIRE_PREBUILT === "1";
  const msg = `[bundle-assets] go not on PATH — skipping prebuilt hivemind-hook binaries.`;
  if (force) {
    console.error(msg + " (HIVE_MIND_REQUIRE_PREBUILT=1 → hard-fail)");
    process.exit(1);
  }
  console.warn(msg + " Users installing from this tarball will need Go 1.20+ at install time.");
} else {
  for (const t of HOOK_TARGETS) {
    const outBin = resolve(prebuiltDir, t.name);
    const env = { ...process.env, GOOS: t.goos, GOARCH: t.goarch, CGO_ENABLED: "0" };
    const res = spawnSync(
      "go",
      ["build", "-trimpath", "-ldflags=-s -w", "-o", outBin, "./cmd/hivemind-hook"],
      { cwd: repoRoot, env, stdio: ["ignore", "pipe", "pipe"], encoding: "utf8" }
    );
    if (res.status !== 0) {
      console.error(`[bundle-assets] FAILED cross-build ${t.goos}/${t.goarch}: ${res.stderr || res.stdout}`);
      process.exit(1);
    }
    builtTargets.push(t.name);
  }
  console.log(`[bundle-assets] cross-built ${builtTargets.length} hivemind-hook binaries`);
}

// Stamp the CLI build so `hivemind version` can report what it shipped.
const pkg = JSON.parse(readFileSync(resolve(cliRoot, "package.json"), "utf8"));
const coreVersion = existsSync(resolve(out, "VERSION"))
  ? readFileSync(resolve(out, "VERSION"), "utf8").trim()
  : "unknown";
writeFileSync(
  resolve(out, "bundled.json"),
  JSON.stringify(
    { cli: pkg.version, core: coreVersion, bundledAt: new Date().toISOString(), prebuiltHooks: builtTargets },
    null,
    2
  )
);
console.log(`[bundle-assets] wrote ${out} (cli=${pkg.version}, core=${coreVersion}, prebuiltHooks=${builtTargets.length})`);
