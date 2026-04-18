import { cpSync, existsSync, mkdirSync, readFileSync, rmSync } from "node:fs";
import { createInterface } from "node:readline/promises";
import { resolve } from "node:path";
import { bundledAssetsDir, hubDir, hubSrcDir } from "../paths.js";
import { run, runBash, which } from "../run.js";
import { validateAdapterName } from "./validate.js";

type InitOpts = {
  adapter?: string;
  memoryRepo?: string;
  yes?: boolean;
  forceStage?: boolean;
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

  // Must probe the actual remote, not just `.git` presence: an init'd hub
  // without an origin still prompts inside setup.sh, which would deadlock
  // a --yes run.
  const hubHasOrigin = existsSync(resolve(hub, ".git"))
    && run("git", ["-C", hub, "remote", "get-url", "origin"], { stdio: ["ignore", "pipe", "pipe"] }).status === 0;
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

  // If HIVE_MIND_SRC is a real git checkout (legacy curl|bash install),
  // don't quietly overwrite the working tree — setup.sh would then take
  // the .git branch and `git pull`, defeating the CLI-owns-upgrades
  // model. Refuse unless the user opts in via --force-stage.
  if (existsSync(resolve(src, ".git")) && !opts.forceStage) {
    console.error(
      `error: ${src} is a git checkout (legacy install). Refusing to overwrite.\n` +
        `  - To convert to a CLI-managed install, rerun with --force-stage.\n` +
        `  - To keep using the cloned install, upgrade via \`cd ${src} && git pull\`.`
    );
    return 1;
  }
  if (opts.forceStage) {
    // Wipe the old .git (and anything else left behind) so the resulting
    // tree is a plain staged set owned by the CLI.
    rmSync(src, { recursive: true, force: true });
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
