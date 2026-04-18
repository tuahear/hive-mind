import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { hubDir, hubSrcDir } from "../paths.js";
import { runBash } from "../run.js";

export function attachCmd(adapter: string): number {
  const src = hubSrcDir();
  const setupSh = resolve(src, "setup.sh");
  if (!existsSync(setupSh)) {
    console.error(`error: hub not initialized. Run \`hivemind init\` first.`);
    return 1;
  }
  if (!existsSync(resolve(src, "adapters", adapter))) {
    console.error(`error: unknown adapter '${adapter}'. Available: see ls ${resolve(src, "adapters")}`);
    return 1;
  }
  return runBash(setupSh, [], {
    ADAPTER: adapter,
    HIVE_MIND_HUB_DIR: hubDir(),
    HIVE_MIND_SKIP_CLONE: "1",
  });
}
