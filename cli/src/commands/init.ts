import { cpSync, existsSync, mkdirSync, readFileSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { resolve } from "node:path";
import { bundledAssetsDir, hubDir, hubSrcDir } from "../paths.js";
import { runBash, which } from "../run.js";

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
  const hub = hubDir();
  const src = hubSrcDir();
  const assets = bundledAssetsDir();

  if (!existsSync(assets) || !existsSync(resolve(assets, "setup.sh"))) {
    console.error(
      `error: bundled assets not found at ${assets}. This CLI build is broken — reinstall hive-mind or re-run \`npm run build\` from the cli/ directory.`
    );
    return 1;
  }

  let memoryRepo = opts.memoryRepo || process.env.MEMORY_REPO || "";
  if (!memoryRepo && existsSync(resolve(hub, ".git"))) {
    // Reuse existing origin if the hub is already initialized.
    memoryRepo = "";
  }
  if (!memoryRepo && !opts.yes) {
    console.log(
      "\nNeed the SSH URL of your PRIVATE memory repo. Create an empty private repo\n" +
        "on GitHub (no README, no .gitignore, no license), then paste its SSH URL.\n" +
        "Example: git@github.com:you/claude-memory.git\n"
    );
    memoryRepo = await prompt("MEMORY_REPO: ");
  }

  // Stage bundled assets into ~/.hive-mind/hive-mind/ so setup.sh finds
  // a pre-populated HIVE_MIND_SRC and skips `git clone`. This is the
  // whole point: no full-repo clone required at install time.
  mkdirSync(src, { recursive: true });
  for (const item of ["core", "adapters", "cmd", "setup.sh", "VERSION", "go.mod"]) {
    const s = resolve(assets, item);
    if (!existsSync(s)) continue;
    cpSync(s, resolve(src, item), { recursive: true });
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
