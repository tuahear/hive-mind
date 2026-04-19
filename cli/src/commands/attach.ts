import { existsSync, readdirSync, statSync } from "node:fs";
function isDir(p: string): boolean {
  try { return statSync(p).isDirectory(); } catch { return false; }
}
import { resolve } from "node:path";
import { hubDir, hubSrcDir } from "../paths.js";
import { runBash } from "../run.js";
import { consumePrevVersionMarker } from "./stage.js";
import { validateAdapterName } from "./validate.js";

function listAdapters(adaptersDir: string): string[] {
  if (!existsSync(adaptersDir)) return [];
  try {
    return readdirSync(adaptersDir)
      .filter((n) => isDir(resolve(adaptersDir, n)) && existsSync(resolve(adaptersDir, n, "adapter.sh")))
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
  // Match setup.sh's contract: adapter dir must exist AND be a directory
  // AND ship an adapter.sh. A plain file or a directory missing the
  // contract script would otherwise sail through the CLI and fail later
  // with a less actionable error inside setup.sh.
  const adaptersDir = resolve(src, "adapters");
  const adapterDir = resolve(adaptersDir, adapter);
  const adapterOk =
    isDir(adapterDir) && existsSync(resolve(adapterDir, "adapter.sh"));
  if (!adapterOk) {
    const available = listAdapters(adaptersDir);
    console.error(
      `error: unknown adapter '${adapter}' (missing ${adapter}/adapter.sh).\n` +
        `  Available: ${available.length ? available.join(", ") : "(none — hub source is empty?)"}`
    );
    return 1;
  }
  const hub = hubDir();
  const env: NodeJS.ProcessEnv = {
    ADAPTER: adapter,
    HIVE_MIND_HUB_DIR: hub,
    // Tell setup.sh this is an attach-only invocation: skip the source-
    // staging, hub-seeding, and memory-repo-clone phases (init already
    // did those). setup.sh's own preflight then verifies the hub really
    // is installed and fails fast with "run init first" otherwise.
    HIVE_MIND_ATTACH_MODE: "1",
  };
  // If a prior `hivemind restage` persisted the pre-stage VERSION,
  // forward it to setup.sh so adapter_migrate still sees the real
  // previous version. Consume the marker on use so a stale value can't
  // contaminate a future unrelated attach.
  const prev = consumePrevVersionMarker(resolve(hub, ".hive-mind-state"));
  if (prev) env.HIVE_MIND_PREV_VERSION = prev;
  // Only advertise CLI-staged state when the source tree is not a
  // normal git checkout with a real `.git` directory. This matches
  // setup.sh's `-d .git` gate: any non-directory `.git` state
  // (missing, file-based worktree/submodule layout, etc.) takes the
  // SKIP_CLONE branch because this installer flow only treats a real
  // `.git` directory as pullable source. Legacy curl|bash installs
  // have a real `.git` dir so they take the `git pull` branch as
  // expected.
  if (!isDir(resolve(src, ".git"))) {
    env.HIVE_MIND_SKIP_CLONE = "1";
  }
  return runBash(setupSh, [], env);
}
