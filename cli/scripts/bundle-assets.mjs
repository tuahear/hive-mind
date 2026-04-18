// Copies the bash core + adapters + Go hook source from the repo root
// into cli/assets/ so they ship inside the published npm tarball. This
// is what removes the "clone the whole repo to install" pain — the CLI
// carries its own copy of the pieces it needs.

import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync, readFileSync } from "node:fs";
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

// Stamp the CLI build so `hivemind version` can report what it shipped.
const pkg = JSON.parse(readFileSync(resolve(cliRoot, "package.json"), "utf8"));
const coreVersion = existsSync(resolve(out, "VERSION"))
  ? readFileSync(resolve(out, "VERSION"), "utf8").trim()
  : "unknown";
writeFileSync(
  resolve(out, "bundled.json"),
  JSON.stringify({ cli: pkg.version, core: coreVersion, bundledAt: new Date().toISOString() }, null, 2)
);
console.log(`[bundle-assets] wrote ${out} (cli=${pkg.version}, core=${coreVersion})`);
