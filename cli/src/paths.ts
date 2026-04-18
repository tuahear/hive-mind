import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { resolve, dirname } from "node:path";

export function hubDir(): string {
  return process.env.HIVE_MIND_HUB_DIR || resolve(homedir(), ".hive-mind");
}

export function hubSrcDir(): string {
  return resolve(hubDir(), "hive-mind");
}

// Location of bundled assets inside the installed npm package. When the CLI
// is run from `dist/cli.js`, `__dirname` points at `<pkg>/dist`, so assets
// live at `<pkg>/assets`.
export function bundledAssetsDir(): string {
  return resolve(__dirname, "..", "assets");
}

export function attachedAdaptersFile(): string {
  return resolve(hubDir(), ".install-state", "attached-adapters");
}

export function readAttachedAdapters(): string[] {
  const f = attachedAdaptersFile();
  if (!existsSync(f)) return [];
  // Match core/hub/sync.sh's parser: skip blank lines and `#` comments.
  return readFileSync(f, "utf8")
    .split(/\r?\n/)
    .map((l) => l.trim())
    .filter((l) => l.length > 0 && !l.startsWith("#"));
}

export function bundledVersion(): { cli: string; core: string } | null {
  const f = resolve(bundledAssetsDir(), "bundled.json");
  if (!existsSync(f)) return null;
  try {
    return JSON.parse(readFileSync(f, "utf8"));
  } catch {
    return null;
  }
}

export function coreVersion(): string | null {
  const v = resolve(hubSrcDir(), "VERSION");
  if (!existsSync(v)) return null;
  return readFileSync(v, "utf8").trim();
}

export { dirname };
