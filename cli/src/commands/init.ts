import { existsSync, readFileSync, rmSync } from "node:fs";
import { consumePrevVersionMarker, stageAssets } from "./stage.js";
import { createInterface } from "node:readline/promises";
import { resolve } from "node:path";
import { bundledAssetsDir, hubDir, hubSrcDir, isHubInstalled, readAttachedAdapters } from "../paths.js";
import { detectUnattachedProviders, printAttachSuggestions } from "./detect.js";
import { run, runBash, which } from "../run.js";

type InitOpts = {
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
  // init is hub-only now: no default adapter, no automatic modification
  // of any tool dir. Users explicitly attach adapters afterward via
  // `hivemind attach <name>`. That makes every write to ~/.claude/
  // ~/.codex/ ~/.agents/ the consequence of an explicit user command.
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
  // a --yes run. Also require `.git` to BE a directory, matching setup.sh's
  // origin-reuse gate (a worktree-style `.git` file would otherwise look
  // like a normal install here).
  const hubHasOrigin = isHubInstalled(hub)
    && run("git", ["-C", hub, "remote", "get-url", "origin"], { stdio: ["ignore", "pipe", "pipe"] }).status === 0;
  let memoryRepo = opts.memoryRepo || process.env.MEMORY_REPO || "";
  if (!memoryRepo && !opts.yes) {
    if (hubHasOrigin) {
      // Reuse existing origin if the hub is already initialized.
    } else {
      console.log(
        "\nNeed the git URL (or local path) of your memory repo. Use any host +\n" +
          "format your git supports — SSH, HTTPS, or a local bare repo.\n" +
          "Examples:\n" +
          "  git@github.com:you/claude-memory.git       (SSH; any host)\n" +
          "  https://git.example.com/you/claude-memory  (HTTPS)\n" +
          "  /path/to/claude-memory.git                 (local bare repo)\n"
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

  // Stage bundled assets into ~/.hive-mind/hive-mind/. Captures the
  // pre-stage VERSION so setup.sh can still see the previous install
  // version even though we're about to overwrite the file.
  const hubStateDir = resolve(hub, ".hive-mind-state");
  const staged = stageAssets(src, assets, hubStateDir);
  if (!staged.ok) return staged.code;
  // Consume the restage-written marker once stageAssets has captured it,
  // so it doesn't linger into an unrelated future upgrade. stageAssets
  // already read it via capturePrevVersion; this just removes it.
  consumePrevVersionMarker(hubStateDir);

  if (!which("bash")) {
    console.error(
      "error: bash not found on PATH. On Windows install Git Bash (https://gitforwindows.org) and rerun."
    );
    return 127;
  }

  const setupSh = resolve(src, "setup.sh");
  const env: NodeJS.ProcessEnv = {
    HIVE_MIND_HUB_DIR: hub,
    // Tell setup.sh not to git-clone over the top of what we just staged.
    HIVE_MIND_SKIP_CLONE: "1",
    // Hub-only mode: skip the adapter-attach and bundled-skills phases.
    // User attaches adapters explicitly via `hivemind attach <name>`.
    HIVE_MIND_HUB_ONLY: "1",
    // Hand setup.sh the pre-staged VERSION so adapter_migrate (when run
    // on a later `hivemind attach`) sees the real previous version, not
    // the one we just wrote during staging.
    HIVE_MIND_PREV_VERSION: staged.prevVersion,
  };
  if (memoryRepo) env.MEMORY_REPO = memoryRepo;

  console.log(`[hivemind] init: hub=${hub} (no adapter attached — use \`hivemind attach <name>\`)`);
  const status = runBash(setupSh, [], env);
  if (status === 0) {
    console.log("");
    console.log(`Hub ready at ${hub}. No adapters attached yet — the hub is idle`);
    console.log(`until you wire up at least one tool.`);
    // Informational detection: which adapters could the user attach?
    // After a hub-only init, readAttachedAdapters() is empty, so every
    // detected provider will surface in the suggestions.
    printAttachSuggestions(detectUnattachedProviders(readAttachedAdapters()));
  }
  return status;
}

export function bundledCoreVersion(): string {
  const v = resolve(bundledAssetsDir(), "VERSION");
  if (!existsSync(v)) return "unknown";
  return readFileSync(v, "utf8").trim();
}
