import { cpSync, existsSync, mkdirSync, rmSync } from "node:fs";
import { resolve } from "node:path";
import { bundledAssetsDir, hubSrcDir } from "../paths.js";

// Minimal upgrade path: copy the CLI's freshly-bundled assets over the
// existing hub source tree, honoring the same "not over a git checkout"
// guard as init. No adapter attach, no memory-repo prompt — just the
// "refresh ~/.hive-mind/hive-mind/" step on its own.
export function restageCmd(opts: { forceStage?: boolean }): number {
  const assets = bundledAssetsDir();
  const src = hubSrcDir();

  if (!existsSync(resolve(assets, "setup.sh"))) {
    console.error(`error: bundled assets missing at ${assets}. CLI build is broken.`);
    return 1;
  }

  if (existsSync(resolve(src, ".git")) && !opts.forceStage) {
    console.error(
      `error: ${src} is a git checkout (legacy install). Refusing to overwrite.\n` +
        `  - To convert to CLI-managed, pass --force-stage (drops the .git first).\n` +
        `  - Otherwise upgrade via \`cd ${src} && git pull\`.`
    );
    return 1;
  }
  if (opts.forceStage) {
    rmSync(src, { recursive: true, force: true });
  }

  mkdirSync(src, { recursive: true });
  const required = ["core", "adapters", "cmd", "setup.sh", "VERSION", "go.mod"];
  for (const item of required) {
    const s = resolve(assets, item);
    if (!existsSync(s)) {
      console.error(`error: bundled asset '${item}' missing from ${assets}.`);
      return 1;
    }
    const dst = resolve(src, item);
    rmSync(dst, { recursive: true, force: true });
    cpSync(s, dst, { recursive: true });
  }

  console.log(`[hivemind] restaged bundled assets into ${src}`);
  console.log(`  Hooks and attached adapters are untouched. Re-run \`hivemind init\` or \`hivemind attach\` if you also need to refresh hook wiring.`);
  return 0;
}
