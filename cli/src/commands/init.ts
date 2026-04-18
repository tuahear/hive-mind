import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { resolve } from "node:path";
import { bundledAssetsDir, hubDir, hubSrcDir } from "../paths.js";
import { runBash, which } from "../run.js";
import { validateAdapterName } from "./validate.js";

type InitOpts = {
  adapter?: string;
  memoryRepo?: string;
  yes?: boolean;
};

async function prompt(question: string): Promise<string> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  try {
    return (await rl.question(question)).trim();
  } finally {
    rl.close();
  }
}

export async function initCmd(opts: InitOpts): Promise<number> {
  const adapter = opts.adapter || "claude-code";
  const nameErr = validateAdapterName(adapter);
  if (nameErr) {
    console.error(`error: ${nameErr}`);
    return 2;
  }
  const hub = hubDir();
  const src = hubSrcDir();
  const assets = bundledAssetsDir();

  if (!existsSync(assets) || !existsSync(resolve(assets, "setup.sh"))) {
    console.error(
      `error: bundled assets not found at ${assets}. This CLI build is broken — reinstall hive-mind or re-run \`npm run build\` from the cli/ directory.`
    );
    return 1;
  }

  const hubHasOrigin = existsSync(resolve(hub, ".git"));
  let memoryRepo = opts.memoryRepo || process.env.MEMORY_REPO || "";
  if (!memoryRepo && !opts.yes) {
    if (hubHasOrigin) {
      // Reuse existing origin if the hub is already initialized.
    } else {
      console.log(
        "\nNeed the SSH URL of your PRIVATE memory repo. Create an empty private repo\n" +
          "on GitHub (no README, no .gitignore, no license), then paste its SSH URL.\n" +
          "Example: git@github.com:you/claude-memory.git\n"
      );
      memoryRepo = await prompt("MEMORY_REPO: ");
    }
  }
  if (!memoryRepo && !hubHasOrigin && opts.yes) {
    // Fail fast instead of handing control to setup.sh, which would block
    // on a bash `read` prompt under --yes.
    console.error(
      "error: --yes requires --memory-repo (or the MEMORY_REPO env var) when the hub has no existing origin."
    );
    return 2;
  }

  // Stage bundled assets into ~/.hive-mind/hive-mind/. Required roots must
  // exist — skipping silently would let a broken CLI build "succeed" with
  // half a core tree. For each root, clear the destination first so
  // upstream file deletions/renames don't leave stale files behind.
  mkdirSync(src, { recursive: true });
  // cmd + go.mod are required: setup.sh always builds the native
  // hivemind-hook launcher for the shipped adapters.
  const required = ["core", "adapters", "cmd", "setup.sh", "VERSION", "go.mod"];
  for (const item of required) {
    const s = resolve(assets, item);
    if (!existsSync(s)) {
      console.error(`error: bundled asset '${item}' missing from ${assets}. CLI build is incomplete.`);
      return 1;
    }
    const dst = resolve(src, item);
    rmSync(dst, { recursive: true, force: true });
    cpSync(s, dst, { recursive: true });
  }

  if (!which("bash")) {
    console.error(
      "error: bash not found on PATH. On Windows install Git Bash (https://gitforwindows.org) and rerun."
    );
    return 127;
  }

  const setupSh = resolve(src, "setup.sh");
  const env: NodeJS.ProcessEnv = {
    ADAPTER: adapter,
    HIVE_MIND_HUB_DIR: hub,
    // Tell setup.sh not to git-clone over the top of what we just staged.
    HIVE_MIND_SKIP_CLONE: "1",
  };
  if (memoryRepo) env.MEMORY_REPO = memoryRepo;

  console.log(`[hivemind] init: adapter=${adapter} hub=${hub}`);
  return runBash(setupSh, [], env);
}

export function bundledCoreVersion(): string {
  const v = resolve(bundledAssetsDir(), "VERSION");
  if (!existsSync(v)) return "unknown";
  return readFileSync(v, "utf8").trim();
}
