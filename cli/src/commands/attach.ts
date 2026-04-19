import { existsSync, readdirSync, statSync } from "node:fs";
function isDir(p: string): boolean {
  try { return statSync(p).isDirectory(); } catch { return false; }
}
import { resolve } from "node:path";
import { hubDir, hubSrcDir } from "../paths.js";
import { runBash } from "../run.js";
import { validateAdapterName } from "./validate.js";

function listAdapters(adaptersDir: string): string[] {
  if (!existsSync(adaptersDir)) return [];
  try {
    return readdirSync(adaptersDir)
      .filter((n) => {
        try {
          return statSync(resolve(adaptersDir, n)).isDirectory();
        } catch {
          return false;
        }
      })
      .sort();
  } catch {
    return [];
  }
}

export function attachCmd(adapter: string): number {
  const nameErr = validateAdapterName(adapter);
  if (nameErr) {
    console.error(`error: ${nameErr}`);
    return 2;
  }
  const src = hubSrcDir();
  const setupSh = resolve(src, "setup.sh");
  if (!existsSync(setupSh)) {
    console.error(`error: hub not initialized. Run \`hivemind init\` first.`);
    return 1;
  }
  const adaptersDir = resolve(src, "adapters");
  if (!existsSync(resolve(adaptersDir, adapter))) {
    const available = listAdapters(adaptersDir);
    console.error(
      `error: unknown adapter '${adapter}'.\n` +
        `  Available: ${available.length ? available.join(", ") : "(none — hub source is empty?)"}`
    );
    return 1;
  }
  const env: NodeJS.ProcessEnv = {
    ADAPTER: adapter,
    HIVE_MIND_HUB_DIR: hubDir(),
  };
  // Only advertise CLI-staged state when the source tree actually is
  // CLI-staged. Align with setup.sh, which enters the SKIP_CLONE branch
  // specifically when `.git` is NOT a directory — a `.git` file (git
  // worktree/submodule-style) is still a real checkout we must not
  // overwrite. Legacy curl|bash installs have a real `.git` dir, so
  // they take the `git pull` branch as expected.
  if (!isDir(resolve(src, ".git"))) {
    env.HIVE_MIND_SKIP_CLONE = "1";
  }
  return runBash(setupSh, [], env);
}
