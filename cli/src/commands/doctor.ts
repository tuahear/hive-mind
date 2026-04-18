import { existsSync } from "node:fs";
import { resolve } from "node:path";
import { hubDir, hubSrcDir, readAttachedAdapters, coreVersion, bundledAssetsDir } from "../paths.js";
import { run, which } from "../run.js";

type Check = { name: string; ok: boolean; detail?: string };

export function doctorCmd(json: boolean): number {
  const hub = hubDir();
  const src = hubSrcDir();
  const checks: Check[] = [];

  checks.push({ name: "bash on PATH", ok: which("bash") });
  checks.push({ name: "git on PATH", ok: which("git") });
  checks.push({ name: "jq on PATH", ok: which("jq") });
  checks.push({ name: "bundled assets present", ok: existsSync(resolve(bundledAssetsDir(), "setup.sh")) });
  checks.push({ name: "hub directory exists", ok: existsSync(hub), detail: hub });
  checks.push({ name: "hub git initialized", ok: existsSync(resolve(hub, ".git")) });
  checks.push({ name: "hub source staged", ok: existsSync(resolve(src, "core", "hub", "sync.sh")) });
  checks.push({ name: "core/VERSION readable", ok: coreVersion() !== null, detail: coreVersion() ?? undefined });

  const attached = readAttachedAdapters();
  checks.push({
    name: "at least one adapter attached",
    ok: attached.length > 0,
    detail: attached.join(", ") || "(none)",
  });

  for (const a of attached) {
    const adapterSh = resolve(src, "adapters", a, "adapter.sh");
    checks.push({ name: `adapter ${a}: contract file present`, ok: existsSync(adapterSh) });
  }

  if (existsSync(resolve(hub, ".git"))) {
    const remote = run("git", ["-C", hub, "remote", "get-url", "origin"], { stdio: ["ignore", "pipe", "pipe"] });
    checks.push({ name: "hub origin configured", ok: remote.status === 0 });
  }

  const failed = checks.filter((c) => !c.ok).length;

  if (json) {
    console.log(JSON.stringify({ checks, failed }, null, 2));
  } else {
    for (const c of checks) {
      const mark = c.ok ? "OK  " : "FAIL";
      console.log(`[${mark}] ${c.name}${c.detail ? `  (${c.detail})` : ""}`);
    }
    console.log(`\n${checks.length - failed}/${checks.length} checks passed`);
  }
  return failed === 0 ? 0 : 1;
}
