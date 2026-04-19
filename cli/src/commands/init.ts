import { existsSync, readFileSync, rmSync } from "node:fs";
import { consumePrevVersionMarker, stageAssets } from "./stage.js";
import { createInterface } from "node:readline/promises";
import { resolve } from "node:path";
import { bundledAssetsDir, hubDir, hubSrcDir, isHubInstalled, readAttachedAdapters } from "../paths.js";
import { detectUnattachedProviders, printAttachSuggestions } from "./detect.js";
import { run, runBash, which } from "../run.js";
import { attachCmd } from "./attach.js";
import { restageCmd } from "./restage.js";

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
  // init is the single "set up / keep up to date" entry point:
  //   - fresh machine (no hub):  stage source, seed hub, clone memory repo
  //   - existing hub:            restage bundled assets, refresh every
  //                              already-attached adapter's hook wiring
  //                              and skills. Fully idempotent upgrade.
  // On first install, users still run `hivemind attach <name>` to wire
  // their tools — init does not implicitly attach anything it wasn't
  // already tracking.
  const hub = hubDir();
  const src = hubSrcDir();
  const assets = bundledAssetsDir();

  if (!existsSync(assets) || !existsSync(resolve(assets, "setup.sh"))) {
    console.error(
      `error: bundled assets not found at ${assets}. This CLI build is broken — reinstall hive-mind or re-run \`npm run build\` from the cli/ directory.`
    );
    return 1;
  }

  // Upgrade branch: hub already exists AND has an origin configured.
  // Restage bundled assets, then re-run each currently-attached
  // adapter's install so its hooks, skills, and launcher binary match
  // the new release. No MEMORY_REPO prompt, no fresh clone — existing
  // hub is preserved.
  //
  // We require origin-present to distinguish "real hub" from "orphan
  // `.git` dir someone created by hand" — the latter should fall
  // through to fresh-init so --memory-repo gets demanded.
  const hubHasOriginPresent = isHubInstalled(hub)
    && run("git", ["-C", hub, "remote", "get-url", "origin"], { stdio: ["ignore", "pipe", "pipe"] }).status === 0;
  if (hubHasOriginPresent) {
    console.log(`[hivemind] existing hub detected at ${hub} — refreshing staged assets.`);
    const restageStatus = restageCmd({ forceStage: !!opts.forceStage });
    if (restageStatus !== 0) return restageStatus;

    const attached = readAttachedAdapters();
    if (attached.length === 0) {
      console.log(`[hivemind] hub has no attached adapters — nothing further to refresh.`);
      console.log(`  Attach a tool with \`hivemind attach <name>\` when ready.`);
      printAttachSuggestions(detectUnattachedProviders([]));
      return 0;
    }

    console.log(`[hivemind] refreshing attached adapters: ${attached.join(", ")}`);
    for (const adapter of attached) {
      console.log(`[hivemind]   -> ${adapter}`);
      const s = attachCmd(adapter);
      if (s !== 0) {
        console.error(`[hivemind] refresh of '${adapter}' failed (status=${s}). Remaining adapters not refreshed.`);
        return s;
      }
    }
    console.log(`[hivemind] done. All attached adapters are up to date.`);
    return 0;
  }

  // Reuse the same probe for the fresh-init branch's --yes failfast.
  const hubHasOrigin = hubHasOriginPresent;
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
