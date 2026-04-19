import { existsSync, mkdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";
import { bundledAssetsDir, hubDir, hubSrcDir } from "../paths.js";
import { stageAssets } from "./stage.js";

// Minimal upgrade path: copy the CLI's freshly-bundled assets over the
// existing hub source tree, honoring the same "not over a git checkout"
// guard as init. No adapter attach, no memory-repo prompt — just the
// "refresh ~/.hive-mind/hive-mind/" step on its own. The captured
// pre-stage VERSION is dropped into .hive-mind-state/prev-version so
// a later `hivemind init` / `hivemind attach` can hand it to setup.sh.
// `quiet: true` skips the trailing caution paragraph — init calls
// restage with quiet=true because init is about to refresh every
// attached adapter's wiring itself, making the "re-run init/attach to
// rebuild the launcher" advice actively misleading in that context.
export function restageCmd(opts: { forceStage?: boolean; quiet?: boolean }): number {
  const assets = bundledAssetsDir();
  const src = hubSrcDir();

  if (existsSync(resolve(src, ".git")) && !opts.forceStage) {
    console.error(
      `error: ${src} is a git checkout (legacy install). Refusing to overwrite.\n` +
        `  - To convert to CLI-managed, pass --force-stage (drops the .git first).\n` +
        `  - Otherwise upgrade via \`cd ${src} && git pull\`.`
    );
    return 1;
  }
  if (opts.forceStage) {
    // rmSync via stageAssets' internal per-root clean doesn't touch
    // `.git`; for --force-stage we want the whole src gone.
    try {
      const { rmSync } = require("node:fs") as typeof import("node:fs");
      rmSync(src, { recursive: true, force: true });
    } catch {}
  }

  const staged = stageAssets(src, assets);
  if (!staged.ok) return staged.code;

  // Persist prev version so the next init/attach can forward it.
  const stateDir = resolve(hubDir(), ".hive-mind-state");
  try {
    mkdirSync(stateDir, { recursive: true });
    writeFileSync(resolve(stateDir, "prev-version"), staged.prevVersion + "\n");
  } catch {
    // Non-fatal — logging only.
  }

  console.log(`[hivemind] restaged bundled assets into ${src}`);
  console.log(`  previous core version: ${staged.prevVersion}`);
  if (!opts.quiet) {
    console.log(
      `  Restage updates the staged hub sources only — it does NOT rebuild the\n` +
        `  installed bin/hivemind-hook launcher under $HIVE_MIND_HUB_DIR/bin/. Hooks\n` +
        `  and attached adapters stay wired to whatever launcher was built at the\n` +
        `  last init/attach. Re-run \`hivemind init\` or \`hivemind attach <adapter>\`\n` +
        `  to rebuild the launcher and refresh hook wiring.`
    );
  }
  return 0;
}
