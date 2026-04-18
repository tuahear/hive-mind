import { existsSync, statSync } from "node:fs";
import { resolve } from "node:path";
import { hubDir, hubSrcDir, readAttachedAdapters, coreVersion, isHubInstalled } from "../paths.js";
import { run, runBash } from "../run.js";

export function statusCmd(json: boolean): number {
  const hub = hubDir();
  const installed = isHubInstalled(hub);
  const attached = readAttachedAdapters();
  const core = coreVersion();

  let lastSyncMs: number | null = null;
  let lastSyncIso: string | null = null;
  const lockOrLog = resolve(hub, ".hive-mind-state");
  if (existsSync(lockOrLog)) {
    try {
      lastSyncMs = statSync(lockOrLog).mtimeMs;
      lastSyncIso = new Date(lastSyncMs).toISOString();
    } catch {}
  }

  // Default to null (unknown) so an uninstalled hub doesn't claim 0
  // unpushed commits — that reads like "everything is in sync" which is
  // the opposite of the truth pre-install.
  let unpushed: number | null = null;
  let originUrl: string | null = null;
  if (installed) {
    unpushed = 0;
    // Probe for an upstream first; without it `rev-list @{u}..HEAD` exits
    // non-zero and we'd silently report "0 unpushed", which is misleading
    // for a freshly-initialised hub that has never been pushed.
    const upstream = run("git", ["-C", hub, "rev-parse", "--abbrev-ref", "@{u}"], { stdio: ["ignore", "pipe", "pipe"] });
    if (upstream.status === 0) {
      const rev = run("git", ["-C", hub, "rev-list", "--count", "@{u}..HEAD"], { stdio: ["ignore", "pipe", "pipe"] });
      if (rev.status === 0) unpushed = parseInt(rev.stdout.trim() || "0", 10) || 0;
    } else {
      unpushed = null;
    }
    const remote = run("git", ["-C", hub, "remote", "get-url", "origin"], { stdio: ["ignore", "pipe", "pipe"] });
    if (remote.status === 0) originUrl = sanitize(remote.stdout.trim());
  }

  const state = {
    hub,
    installed,
    core,
    attached,
    originUrl,
    lastSync: lastSyncIso,
    unpushedCommits: unpushed,
  };

  if (json) {
    console.log(JSON.stringify(state, null, 2));
    return 0;
  }

  console.log(`hub:             ${hub}`);
  console.log(`installed:       ${installed ? "yes" : "no"}`);
  console.log(`core version:    ${core ?? "(not installed)"}`);
  console.log(`attached:        ${attached.length ? attached.join(", ") : "(none)"}`);
  console.log(`origin:          ${originUrl ?? "(unset)"}`);
  console.log(`last activity:   ${lastSyncIso ?? "(never)"}`);
  console.log(`unpushed commits: ${unpushed === null ? "(no upstream)" : unpushed}`);
  return 0;
}

function sanitize(url: string): string {
  return url.replace(/:\/\/[^@/]+@/, "://***@");
}

export function syncCmd(force: boolean): number {
  const bin = resolve(hubDir(), "bin", process.platform === "win32" ? "sync" : "sync");
  const syncSh = resolve(hubSrcDir(), "core", "hub", "sync.sh");
  const target = existsSync(bin) ? bin : existsSync(syncSh) ? syncSh : null;
  if (!target) {
    console.error("error: no sync entrypoint found. Run `hivemind init` first.");
    return 1;
  }
  const args = force ? ["--force-push"] : [];
  // runBash (not raw run) so a missing bash emits the ENOENT guidance
  // message other commands already use.
  return runBash(target, args);
}

export function pullCmd(): number {
  const hub = hubDir();
  if (!isHubInstalled(hub)) {
    console.error("error: hub not initialized. Run `hivemind init` first.");
    return 1;
  }
  const res = run("git", ["-C", hub, "pull", "--rebase", "--autostash"], { stdio: "inherit" });
  return res.status;
}
